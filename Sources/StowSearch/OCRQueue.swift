import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Logging
import os
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
/// extra state. Each item is read, decrypted and recognised outside any
/// database transaction; only short writes take the write lock, so OCR never
/// holds up import for longer than one small transaction.
///
/// One bad attachment cannot block the queue (A-03, D-481, D-502). Each try is
/// counted in its own transaction before the file is decrypted, so a crash or
/// kill still counts; an item that has used up `maximumAttempts` is marked
/// failed and skipped. Each item runs under a time limit on a thread of its
/// own; at the limit it is marked failed and the run stops (the stuck thread
/// is abandoned), so the next run starts at the next item. A failed item is
/// tried again only by a newer `version` (`requeueAfterUpdate`).
public final class OCRQueue: Sendable {
    /// Scanned PDFs longer than this are recognised up to this many pages.
    public static let maximumPages = 50
    static let version = 1
    /// Tries per item that may never finish before it is marked failed (D-502).
    public static let maximumAttempts = 3
    /// Longest one item may take: up to 50 pages through Vision (D-502).
    static let itemTimeLimit: Duration = .seconds(600)
    /// One stuck item at a time: while it still runs, no more OCR starts in this process.
    static let maximumAbandoned = 1
    private static let sharedAbandoned = OSAllocatedUnfairLock(initialState: 0)

    let archive: Archive
    let recogniser: @Sendable (CGImage) throws -> String
    let limit: TimeLimit
    /// `version`, except in tests of retrying after an update.
    let ocrVersion: Int
    let logger = Logger(label: "ee.getstow.search.ocr")

    public init(archive: Archive) {
        self.archive = archive
        recogniser = OCRQueue.visionText
        limit = TimeLimit(limit: Self.itemTimeLimit, maximumAbandoned: Self.maximumAbandoned, abandoned: Self.sharedAbandoned)
        ocrVersion = Self.version
    }

    /// For tests: a stand-in recogniser, a time limit with its own count, and a version.
    init(archive: Archive, recogniser: @escaping @Sendable (CGImage) throws -> String,
         limit: TimeLimit = TimeLimit(limit: .seconds(60), maximumAbandoned: 1, abandoned: OSAllocatedUnfairLock(initialState: 0)),
         version: Int = OCRQueue.version) {
        self.archive = archive
        self.recogniser = recogniser
        self.limit = limit
        ocrVersion = version
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
    /// Throws `OCRError.timedOut` after marking an item that did not finish in
    /// time, so the run stops and the next run moves on.
    @discardableResult
    public func runNext() throws -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        // The try is recorded and committed before the file is decrypted or read.
        let next = try archive.database.write { db -> Row? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, content_hash, mime_type, text_attempts FROM attachments WHERE text_status = 'ocr_pending' ORDER BY id LIMIT 1
                """) else { return nil }
            try db.execute(sql: "UPDATE attachments SET text_attempts = text_attempts + 1, text_last_attempt_at = ? WHERE id = ?",
                           arguments: [now, row["id"] as Int64])
            return row
        }
        guard let next else { return false }
        let id: Int64 = next["id"]
        let hash: Data = next["content_hash"]
        let mimeType: String = next["mime_type"] ?? ""
        let attempt = (next["text_attempts"] as Int) + 1

        if attempt > Self.maximumAttempts {
            logger.warning("OCR never finished on this item; marked failed", metadata: ["attachment": "\(id)", "attempts": "\(attempt - 1)"])
            try record(id, attempt: attempt, text: nil)
            return true
        }

        let work: @Sendable () -> Result<String, any Error> = { [self] in
            Result { try autoreleasepool { try recognise(try archive.attachmentFiles.read(hash), mimeType: mimeType) } }
        }
        switch limit.run(work) {
        case .finished(.success(let text)):
            try record(id, attempt: attempt, text: text)
        case .finished(.failure(let error)):
            logger.warning("OCR failed", metadata: ["attachment": "\(id)", "error": "\(Redact.scrub(String(describing: error)))"])
            try record(id, attempt: attempt, text: nil)
        case .timedOut:
            logger.warning("OCR did not finish in time; marked failed and abandoned", metadata: ["attachment": "\(id)"])
            try record(id, attempt: attempt, text: nil)
            throw OCRError.timedOut
        case .tooManyStuck:
            // Not this item's fault: take its try back.
            try archive.database.write { db in
                try db.execute(sql: "UPDATE attachments SET text_attempts = max(text_attempts - 1, 0) WHERE id = ?", arguments: [id])
            }
            throw OCRError.tooManyStuck
        }
        return true
    }

    /// Writes an item's result: its text, or failed with this version. Only if
    /// the row is still the try that was counted, so a stuck call that finishes
    /// late changes nothing.
    private func record(_ id: Int64, attempt: Int, text: String?) throws {
        try archive.database.write { db in
            let current = try Int.fetchOne(db, sql: "SELECT text_attempts FROM attachments WHERE id = ? AND text_status = 'ocr_pending'",
                                           arguments: [id])
            guard current == attempt else { return }
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
                            """, arguments: [id, String(trimmed.prefix(TextExtractor.maximumCharacters)), ocrVersion, now])
                    }
                    try db.execute(sql: "UPDATE attachments SET text_status = 'ocr_done', text_failed_version = NULL, text_attempts = 0 WHERE id = ?",
                                   arguments: [id])
                } else {
                    try db.execute(sql: "UPDATE attachments SET text_status = 'ocr_failed', text_failed_version = ?, text_attempts = 0 WHERE id = ?",
                                   arguments: [ocrVersion, id])
                }
            }
        }
    }

    /// Puts back in the queue every item a older OCR version failed on, for one
    /// more round with the same limit. Its count is already 0 from when it was marked.
    @discardableResult
    public func requeueAfterUpdate() throws -> Int {
        try archive.database.write { db in
            try db.execute(sql: """
                UPDATE attachments SET text_status = 'ocr_pending', text_failed_version = NULL
                WHERE text_status = 'ocr_failed' AND text_failed_version < ?
                """, arguments: [ocrVersion])
            return db.changesCount
        }
    }

    /// Works through the queue one item at a time at background priority,
    /// until it is empty, `limit` items are done, or the task is cancelled.
    /// Items an older OCR version failed on go back in the queue first.
    /// Returns the number processed.
    public func run(limit: Int = .max) async throws -> Int {
        let queue = self
        return try await Task.detached(priority: .background) {
            try queue.requeueAfterUpdate()
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

    public enum OCRError: Error, CustomStringConvertible {
        case unreadable
        /// An item did not finish within `itemTimeLimit`; it is marked failed.
        case timedOut
        /// An item from an earlier run in this process is still stuck; restart to carry on.
        case tooManyStuck

        public var description: String {
            switch self {
            case .unreadable: "The file could not be opened as an image or PDF."
            case .timedOut: "Text recognition did not finish in time on one attachment; it is marked as unreadable and the next run moves on."
            case .tooManyStuck: "Text recognition is still stuck on an earlier attachment in this process; run it again to carry on."
            }
        }
    }

}
