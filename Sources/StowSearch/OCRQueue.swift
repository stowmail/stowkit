import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Logging
import PDFKit
import StowCore
import StowStore
import Vision

/// Counts for `stowmail ocr status`.
public struct OCRStatus: Sendable, Equatable, CustomStringConvertible {
    public var pending: Int
    public var done: Int
    public var failed: Int
    /// Messages that still show "OCR pending".
    public var messagesWaiting: Int

    public var description: String {
        "\(pending) pending (\(messagesWaiting) messages waiting), \(done) done, \(failed) failed"
    }
}

/// The OCR queue (brief step 7, D-207): attachments with
/// `text_status = 'ocr_pending'`, worked through one at a time with Apple
/// Vision on-device.
///
/// The queue is the database column itself, so it survives restarts with no
/// extra state: an item interrupted half way is simply still pending. Each item
/// is read, decrypted and recognised outside any database transaction; only the
/// short write of its result takes the write lock, so OCR never holds up import
/// for longer than one small transaction.
public final class OCRQueue: Sendable {
    /// Scanned PDFs longer than this are recognised up to this many pages.
    public static let maximumPages = 50
    static let version = 1

    let archive: Archive
    let recogniser: @Sendable (CGImage) throws -> String
    let logger = Logger(label: "uk.getstow.search.ocr")

    public init(archive: Archive) {
        self.archive = archive
        recogniser = OCRQueue.visionText
    }

    /// For tests: a stand-in recogniser.
    init(archive: Archive, recogniser: @escaping @Sendable (CGImage) throws -> String) {
        self.archive = archive
        self.recogniser = recogniser
    }

    public func status() throws -> OCRStatus {
        try archive.database.read { db in
            let counts = try Row.fetchAll(db, sql: """
                SELECT text_status, count(*) AS n FROM attachments
                WHERE text_status IN ('ocr_pending', 'ocr_done', 'ocr_failed') GROUP BY text_status
                """)
            var map: [String: Int] = [:]
            for row in counts { map[row["text_status"]] = row["n"] }
            let waiting = try Int.fetchOne(db, sql: """
                SELECT count(DISTINCT ma.message_id) FROM message_attachments ma
                JOIN attachments a ON a.id = ma.attachment_id WHERE a.text_status = 'ocr_pending'
                """) ?? 0
            return OCRStatus(pending: map["ocr_pending"] ?? 0, done: map["ocr_done"] ?? 0,
                             failed: map["ocr_failed"] ?? 0, messagesWaiting: waiting)
        }
    }

    /// Processes the oldest pending item. Returns false when the queue is empty.
    @discardableResult
    public func runNext() throws -> Bool {
        let next = try archive.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, content_hash, mime_type FROM attachments WHERE text_status = 'ocr_pending' ORDER BY id LIMIT 1
                """)
        }
        guard let next else { return false }
        let id: Int64 = next["id"]
        let hash: Data = next["content_hash"]
        let mimeType: String = next["mime_type"] ?? ""

        var text: String?
        do {
            let data = try archive.attachmentFiles.read(hash)
            text = try autoreleasepool { try recognise(data, mimeType: mimeType) }
        } catch {
            logger.warning("OCR failed", metadata: ["attachment": "\(id)", "error": "\(Redact.scrub(String(describing: error)))"])
        }

        try archive.database.write { db in
            let now = Int(Date().timeIntervalSince1970)
            // The index is built from the attachment text, so every message
            // containing it is taken out of the index and put back (D-030).
            let messages = try SearchIndexWriter.messages(containing: id, db)
            try SearchIndexWriter.updating(db, messageIDs: messages) {
                if let text {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        try db.execute(sql: """
                            INSERT INTO attachment_text (attachment_id, text, method, extractor_version, extracted_at)
                            VALUES (?, ?, 'ocr', ?, ?)
                            ON CONFLICT (attachment_id) DO UPDATE SET text = excluded.text, method = 'ocr',
                                extractor_version = excluded.extractor_version, extracted_at = excluded.extracted_at
                            """, arguments: [id, String(trimmed.prefix(TextExtractor.maximumCharacters)), Self.version, now])
                    }
                    try db.execute(sql: "UPDATE attachments SET text_status = 'ocr_done' WHERE id = ?", arguments: [id])
                } else {
                    try db.execute(sql: "UPDATE attachments SET text_status = 'ocr_failed' WHERE id = ?", arguments: [id])
                }
            }
        }
        return true
    }

    /// Works through the queue one item at a time at background priority,
    /// until it is empty, `limit` items are done, or the task is cancelled.
    /// Returns the number processed.
    public func run(limit: Int = .max) async throws -> Int {
        let queue = self
        return try await Task.detached(priority: .background) {
            var processed = 0
            while processed < limit, !Task.isCancelled, try queue.runNext() {
                processed += 1
            }
            return processed
        }.value
    }

    // MARK: - Recognition

    func recognise(_ data: Data, mimeType: String) throws -> String {
        if mimeType == "application/pdf" {
            guard let document = PDFDocument(data: data) else { throw OCRError.unreadable }
            var pages: [String] = []
            for index in 0..<min(document.pageCount, Self.maximumPages) {
                guard let page = document.page(at: index), let image = Self.render(page) else { continue }
                pages.append(try recogniser(image))
            }
            return pages.joined(separator: "\n\n")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw OCRError.unreadable }
        return try recogniser(image)
    }

    /// Renders a PDF page at about 200 dpi, capped so huge pages stay manageable.
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(200.0 / 72.0, 4000 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// On-device text recognition with Apple Vision (accurate level, language correction on).
    @Sendable static func visionText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    enum OCRError: Error {
        case unreadable
    }
}
