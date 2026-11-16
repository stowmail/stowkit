import CoreGraphics
import Foundation
import ImageIO
import os
import PDFKit
import StowCore
import Vision

/// Apple's parsers on attachment bytes (security review L-2): PDFKit for a PDF's text
/// layer, the .docx reader (a zip and XMLParser), and PDFKit with Vision for OCR.
///
/// This module depends on `StowCore` alone, so it can be linked by a process that holds
/// no keys and cannot open the archive: the Mac app's extraction helper. Nothing here
/// writes a file or opens a connection; bytes come in and text goes out.
public enum AttachmentParsers {
    /// Scanned PDFs longer than this are recognised up to this many pages.
    public static let maximumPages = 50
    public static let docxType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    /// What one request makes of its bytes, with no time limit: the caller sets one.
    /// Throws only for recognition, when the file is not an image or PDF Vision can be given,
    /// or when Vision fails.
    public static func read(_ request: AttachmentTextRequest) throws -> ExtractionResult {
        switch request.purpose {
        case .text:
            if request.type == "application/pdf" { return pdfText(request.data) }
            if request.type == docxType { return docxText(request.data) }
            return .unsupported
        case .recognition:
            // Cut as the OCR queue cuts it, so an answer from a helper is never larger than what is kept.
            let text = try recognise(request.data, mimeType: request.type)
            return ExtractionResult(status: .ocrDone, text: String(text.prefix(ExtractionResult.maximumCharacters)), method: .ocr)
        }
    }

    /// A PDF's text layer. One with pages but no text goes to the OCR queue.
    public static func pdfText(_ data: Data) -> ExtractionResult {
        guard let document = PDFDocument(data: data) else { return .unsupported }
        if document.isLocked { return .unsupported }
        let text = document.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return document.pageCount > 0 ? .ocrPending : .none
        }
        return .text(text, method: .pdfkit)
    }

    public static func docxText(_ data: Data) -> ExtractionResult {
        guard let xml = ZipReader(data).entry(named: "word/document.xml") else { return .unsupported }
        let collector = DocxTextCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return .text(collector.text, method: .docx)
    }

    // MARK: - Recognition

    public static func recognise(_ data: Data, mimeType: String,
                                 recogniser: (CGImage) throws -> String = visionText) throws -> String {
        if mimeType == "application/pdf" {
            guard let document = PDFDocument(data: data) else { throw RecognitionError.unreadable }
            var pages: [String] = []
            for index in 0..<min(document.pageCount, maximumPages) {
                guard let page = document.page(at: index), let image = render(page) else { continue }
                pages.append(try recogniser(image))
            }
            return pages.joined(separator: "\n\n")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RecognitionError.unreadable }
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
    @Sendable public static func visionText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    public enum RecognitionError: Error, CustomStringConvertible {
        case unreadable

        public var description: String { "The file could not be opened as an image or PDF." }
    }
}

/// The command-line tool's reader (L-2): Apple's parsers in this process, under
/// D-495's and D-502's time limits, with one count of stuck calls per process.
/// The Mac app never uses it; its login item sends the bytes to the helper.
public struct LocalTextReader: AttachmentTextReading {
    private static let textAbandoned = OSAllocatedUnfairLock(initialState: 0)
    private static let recognitionAbandoned = OSAllocatedUnfairLock(initialState: 0)

    let reader: InProcessTextReader

    public init() {
        reader = InProcessTextReader(
            parse: AttachmentParsers.read,
            textLimit: TimeLimit(limit: InProcessTextReader.textTimeLimit, maximumAbandoned: InProcessTextReader.maximumAbandonedText,
                                 abandoned: Self.textAbandoned),
            recognitionLimit: TimeLimit(limit: InProcessTextReader.recognitionTimeLimit,
                                        maximumAbandoned: InProcessTextReader.maximumAbandonedRecognition,
                                        abandoned: Self.recognitionAbandoned))
    }

    public func read(_ request: AttachmentTextRequest) -> AttachmentTextOutcome {
        reader.read(request)
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
        if inText, text.utf8.count < ExtractionResult.maximumCharacters * 4 { text += string }
    }
}
