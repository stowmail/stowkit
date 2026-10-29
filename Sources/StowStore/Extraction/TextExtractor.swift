import Foundation
import os
import PDFKit
import StowCore

/// What text extraction made of one attachment.
public struct ExtractionResult: Sendable, Equatable {
    public enum Method: String, Sendable {
        case plain
        case pdfkit
        case docx
        case ocr
    }

    /// Mirrors `attachments.text_status`.
    public enum Status: String, Sendable {
        case none
        case extracted
        case ocrPending = "ocr_pending"
        case ocrDone = "ocr_done"
        case ocrFailed = "ocr_failed"
        case unsupported
    }

    public var status: Status
    public var text: String?
    public var method: Method?
    /// Reading was tried and did not finish (D-481): recorded as
    /// `text_failed_version`, so a newer extractor tries again. False for a
    /// type Stow does not read.
    public var failed: Bool

    static let none = ExtractionResult(status: .none)
    static let unsupported = ExtractionResult(status: .unsupported)
    static let ocrPending = ExtractionResult(status: .ocrPending)
    /// Stored with no text because reading it did not finish in time.
    static let unreadable = ExtractionResult(status: .unsupported, failed: true)

    public init(status: Status, text: String? = nil, method: Method? = nil, failed: Bool = false) {
        self.status = status
        self.text = text
        self.method = method
        self.failed = failed
    }
}

/// Inline text extraction at import (brief step 5): cheap work only. Image
/// attachments and PDFs without a text layer are queued for OCR instead.
public struct TextExtractor: Sendable {
    /// Bumped when extraction output changes, so attachments can be re-extracted.
    public static let version = 1
    /// Longest text kept per attachment, in characters. Search quality does not
    /// improve past this, and it keeps a pathological file from bloating the index.
    public static let maximumCharacters = 1_000_000
    /// Most decoded text read from one body part or text attachment (D-495).
    /// The part itself is always stored whole; only its search text is cut.
    static let maximumTextBytes = 10 << 20
    /// Longest PDFKit may spend on one attachment at import (D-495).
    static let pdfTimeLimit: Duration = .seconds(30)
    /// PDFKit calls still running past their limit. A thread cannot be
    /// stopped from outside, so a stuck one is abandoned; past this many,
    /// PDFs get no text rather than another thread (D-495).
    static let maximumAbandoned = 4
    private static let sharedAbandoned = OSAllocatedUnfairLock(initialState: 0)
    /// Extraction tries per attachment in a retry round after an update (D-502).
    public static let maximumAttempts = 3
    static let ocrImageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/jpg", "image/tiff", "image/heic", "image/heif", "image/gif", "image/bmp", "image/webp",
    ]
    static let docxType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    let pdfText: @Sendable (Data) -> ExtractionResult
    let pdfLimit: Duration
    /// Shared by every extractor in the process, except in tests.
    let abandoned: OSAllocatedUnfairLock<Int>

    public init() {
        self.init(pdfText: Self.pdfKitText, pdfLimit: Self.pdfTimeLimit, abandoned: Self.sharedAbandoned)
    }

    /// Tests pass a stand-in for PDFKit, a shorter limit and their own count.
    init(pdfText: @escaping @Sendable (Data) -> ExtractionResult, pdfLimit: Duration,
         abandoned: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)) {
        self.pdfText = pdfText
        self.pdfLimit = pdfLimit
        self.abandoned = abandoned
    }

    public func extract(_ attachment: ParsedAttachment) -> ExtractionResult {
        let type = Self.effectiveType(attachment)
        if type == "application/pdf" { return pdf(attachment.data) }
        if type == Self.docxType { return docx(attachment.data) }
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

    /// Runs PDFKit on its own thread under `pdfLimit`, so a PDF that hangs it
    /// cannot stall import. On timeout the attachment is stored with no text,
    /// marked as unreadable (D-481), and the thread is left to finish or hang
    /// on its own: there is no safe way to stop it.
    func pdf(_ data: Data) -> ExtractionResult {
        let work = pdfText
        switch TimeLimit(limit: pdfLimit, maximumAbandoned: Self.maximumAbandoned, abandoned: abandoned).run({ work(data) }) {
        case .finished(let result): return result
        case .timedOut, .tooManyStuck: return .unreadable
        }
    }

    static func pdfKitText(_ data: Data) -> ExtractionResult {
        guard let document = PDFDocument(data: data) else { return .unsupported }
        if document.isLocked { return .unsupported }
        let text = document.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return document.pageCount > 0 ? .ocrPending : .none
        }
        return Self.result(text, method: .pdfkit)
    }

    func docx(_ data: Data) -> ExtractionResult {
        guard let xml = ZipReader(data).entry(named: "word/document.xml") else { return .unsupported }
        let collector = DocxTextCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return Self.result(collector.text, method: .docx)
    }

    /// `text` cut to at most `maximumTextBytes` of UTF-8, at a character boundary.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > maximumTextBytes else { return text }
        let end = text.utf8.index(text.utf8.startIndex, offsetBy: maximumTextBytes)
        return String(text[..<end])
    }

    static func result(_ text: String, method: ExtractionResult.Method) -> ExtractionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let capped = trimmed.count > maximumCharacters ? String(trimmed.prefix(maximumCharacters)) : trimmed
        return ExtractionResult(status: .extracted, text: capped, method: method)
    }
}

/// Collects the text runs (`<w:t>`) of a Word document, with a line break per
/// paragraph (`</w:p>`) and a tab per `<w:tab/>`.
private final class DocxTextCollector: NSObject, XMLParserDelegate {
    var text = ""
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:t": inText = true
        case "w:tab": text += "\t"
        case "w:br", "w:cr": text += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "w:t": inText = false
        case "w:p": text += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText, text.utf8.count < TextExtractor.maximumCharacters * 4 { text += string }
    }
}
