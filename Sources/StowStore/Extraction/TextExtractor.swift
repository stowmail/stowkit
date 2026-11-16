import Foundation
import os
import StowCore

/// The result and time-limit types moved to `StowCore` with the reader seam (L-2);
/// these keep their names for everything that imports only `StowStore`.
public typealias ExtractionResult = StowCore.ExtractionResult
public typealias TimeLimit = StowCore.TimeLimit

/// Inline text extraction at import (brief step 5): cheap work only. Image
/// attachments and PDFs without a text layer are queued for OCR instead.
///
/// Plain text and HTML are read here. PDFs and Word documents go to Apple's
/// parsers through `reader` (security review L-2): in this process for the
/// command-line tool, in a helper that holds no keys for the Mac app.
public struct TextExtractor: Sendable {
    /// Bumped when extraction output changes, so attachments can be re-extracted.
    public static let version = 1
    /// Longest text kept per attachment, in characters (`ExtractionResult.maximumCharacters`).
    public static let maximumCharacters = ExtractionResult.maximumCharacters
    /// Most decoded text read from one body part or text attachment (D-495).
    /// The part itself is always stored whole; only its search text is cut.
    static let maximumTextBytes = 10 << 20
    /// Longest PDFKit may spend on one attachment at import (D-495).
    static let pdfTimeLimit = InProcessTextReader.textTimeLimit
    /// PDFKit calls still running past their limit in this process before PDFs get no text (D-495).
    static let maximumAbandoned = InProcessTextReader.maximumAbandonedText
    /// Extraction tries per attachment in a retry round after an update (D-502).
    public static let maximumAttempts = 3
    static let ocrImageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/jpg", "image/tiff", "image/heic", "image/heif", "image/gif", "image/bmp", "image/webp",
    ]
    static let docxType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    let reader: any AttachmentTextReading

    public init(reader: any AttachmentTextReading) {
        self.reader = reader
    }

    /// Tests pass a stand-in for PDFKit, a shorter limit and their own count.
    init(pdfText: @escaping @Sendable (Data) -> ExtractionResult, pdfLimit: Duration,
         abandoned: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)) {
        reader = InProcessTextReader(
            parse: { request in request.type == "application/pdf" ? pdfText(request.data) : .unsupported },
            textLimit: TimeLimit(limit: pdfLimit, maximumAbandoned: InProcessTextReader.maximumAbandonedText, abandoned: abandoned),
            recognitionLimit: TimeLimit(limit: InProcessTextReader.recognitionTimeLimit, maximumAbandoned: 1,
                                        abandoned: OSAllocatedUnfairLock(initialState: 0)))
    }

    public func extract(_ attachment: ParsedAttachment) -> ExtractionResult {
        let type = Self.effectiveType(attachment)
        if type == "application/pdf" { return pdf(attachment.data) }
        if type == Self.docxType { return parsed(attachment.data, type: type) }
        if type.hasPrefix("text/") || type == "application/ics" || type == "application/json" {
            let text = Self.capped(Charset.decode(attachment.data, charset: nil).text)
            let cleaned = type == "text/html" ? HTMLText.text(fromHTML: text) : text
            return Self.result(cleaned, method: .plain)
        }
        if Self.ocrImageTypes.contains(type) {
            // Inline images are mostly logos and signatures: not worth OCR.
            return attachment.disposition == .inline ? .none : .ocrPending
        }
        return .unsupported
    }

    /// The declared type, corrected from the file name when the sender used a
    /// generic type such as application/octet-stream.
    static func effectiveType(_ attachment: ParsedAttachment) -> String {
        let declared = attachment.declaredMimeType
        guard declared == "application/octet-stream" || declared == "application/x-download" || !declared.contains("/"),
              let name = attachment.filename?.lowercased()
        else { return declared }
        let byExtension: [String: String] = [
            "pdf": "application/pdf", "docx": docxType, "txt": "text/plain", "csv": "text/csv", "ics": "text/calendar",
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "tif": "image/tiff", "tiff": "image/tiff",
            "heic": "image/heic", "html": "text/html", "htm": "text/html",
        ]
        return byExtension[(name as NSString).pathExtension] ?? declared
    }

    /// A PDF's text through the reader. On a time-out, a crash or no answer the
    /// attachment is stored with no text, marked as unreadable (D-481), and a
    /// newer extractor tries it again (D-502).
    func pdf(_ data: Data) -> ExtractionResult {
        parsed(data, type: "application/pdf")
    }

    private func parsed(_ data: Data, type: String) -> ExtractionResult {
        switch reader.read(AttachmentTextRequest(data: data, type: type, purpose: .text)) {
        case .finished(let result): return result
        case .failed, .timedOut, .unavailable: return .unreadable
        }
    }

    /// `text` cut to at most `maximumTextBytes` of UTF-8, at a character boundary.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > maximumTextBytes else { return text }
        let end = text.utf8.index(text.utf8.startIndex, offsetBy: maximumTextBytes)
        return String(text[..<end])
    }

    static func result(_ text: String, method: ExtractionResult.Method) -> ExtractionResult {
        .text(text, method: method)
    }
}
