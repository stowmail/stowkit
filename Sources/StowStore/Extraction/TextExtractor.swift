import Foundation
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

    static let none = ExtractionResult(status: .none)
    static let unsupported = ExtractionResult(status: .unsupported)
    static let ocrPending = ExtractionResult(status: .ocrPending)

    public init(status: Status, text: String? = nil, method: Method? = nil) {
        self.status = status
        self.text = text
        self.method = method
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
    static let maximumPlainBytes = 10 << 20
    static let ocrImageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/jpg", "image/tiff", "image/heic", "image/heif", "image/gif", "image/bmp", "image/webp",
    ]
    static let docxType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    public init() {}

    public func extract(_ attachment: ParsedAttachment) -> ExtractionResult {
        let type = Self.effectiveType(attachment)
        if type == "application/pdf" { return pdf(attachment.data) }
        if type == Self.docxType { return docx(attachment.data) }
        if type.hasPrefix("text/") || type == "application/ics" || type == "application/json" {
            guard attachment.data.count <= Self.maximumPlainBytes else { return .unsupported }
            let text = Charset.decode(attachment.data, charset: nil).text
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

    func pdf(_ data: Data) -> ExtractionResult {
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
