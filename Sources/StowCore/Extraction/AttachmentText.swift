import Foundation
import os

/// What text extraction made of one attachment.
public struct ExtractionResult: Sendable, Equatable, Codable {
    public enum Method: String, Sendable, Codable {
        case plain
        case pdfkit
        case docx
        case ocr
    }

    /// Mirrors `attachments.text_status`.
    public enum Status: String, Sendable, Codable {
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

    public static let none = ExtractionResult(status: .none)
    public static let unsupported = ExtractionResult(status: .unsupported)
    public static let ocrPending = ExtractionResult(status: .ocrPending)
    /// Stored with no text because reading it did not finish in time.
    public static let unreadable = ExtractionResult(status: .unsupported, failed: true)

    /// Longest text kept per attachment, in characters. Search quality does not
    /// improve past this, and it keeps a pathological file from bloating the index.
    public static let maximumCharacters = 1_000_000

    public init(status: Status, text: String? = nil, method: Method? = nil, failed: Bool = false) {
        self.status = status
        self.text = text
        self.method = method
        self.failed = failed
    }

    /// Text read by `method`: trimmed, cut to `maximumCharacters`, `none` when empty.
    public static func text(_ text: String, method: Method) -> ExtractionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let capped = trimmed.count > maximumCharacters ? String(trimmed.prefix(maximumCharacters)) : trimmed
        return ExtractionResult(status: .extracted, text: capped, method: method)
    }
}

/// One attachment's bytes for an Apple parser (security review L-2): the seam between
/// the engine and whatever runs PDFKit, Vision and the .docx reader. The command-line
/// tool reads in its own process (`LocalTextReader` in `StowExtraction`); the Mac app's
/// login item sends the bytes to a helper process that holds no keys.
public struct AttachmentTextRequest: Sendable, Equatable {
    public enum Purpose: String, Sendable, Codable {
        /// Inline text at import: a PDF's text layer or a Word document's text.
        case text
        /// Recognising the text in an image or a scanned PDF (the OCR queue).
        case recognition
    }

    /// The decrypted attachment. Kept in memory only, never written out (L-2).
    public var data: Data
    /// The effective MIME type (`TextExtractor.effectiveType`).
    public var type: String
    public var purpose: Purpose

    public init(data: Data, type: String, purpose: Purpose) {
        self.data = data
        self.type = type
        self.purpose = purpose
    }
}

/// How a request ended. Mirrors `TimeLimit.Outcome`, plus a reader that failed outright.
public enum AttachmentTextOutcome: Sendable, Equatable {
    /// For `.text`, what import stores. For `.recognition`, `ocrDone` with the text.
    case finished(ExtractionResult)
    /// The parser threw, crashed or answered with something unusable.
    case failed
    /// Still running at the limit: abandoned in this process, or the helper ended.
    case timedOut
    /// Not started: earlier work is still stuck, or the helper cannot be reached.
    case unavailable
}

/// Reads attachment text with Apple's parsers (L-2). Called synchronously, from
/// the importer's own thread or the OCR queue's.
public protocol AttachmentTextReading: Sendable {
    func read(_ request: AttachmentTextRequest) -> AttachmentTextOutcome
}

/// Runs a parser in this process under the time limits of D-495 and D-502: PDFKit
/// at import 30 seconds, at most 4 abandoned; each OCR item 600 seconds, at most 1
/// abandoned. Only PDFs get a limit at import, as before the seam. The parser
/// itself (`parse`) comes from `StowExtraction`, or from a test.
public struct InProcessTextReader: AttachmentTextReading {
    /// Longest PDFKit may spend on one attachment at import (D-495).
    public static let textTimeLimit: Duration = .seconds(30)
    /// PDFKit calls still running past their limit; past this many, PDFs get no text (D-495).
    public static let maximumAbandonedText = 4
    /// Longest one OCR item may take: up to 50 pages through Vision (D-502).
    public static let recognitionTimeLimit: Duration = .seconds(600)
    /// One stuck OCR item at a time: while it still runs, no more OCR starts in this process.
    public static let maximumAbandonedRecognition = 1

    let parse: @Sendable (AttachmentTextRequest) throws -> ExtractionResult
    let textLimit: TimeLimit
    let recognitionLimit: TimeLimit

    public init(parse: @escaping @Sendable (AttachmentTextRequest) throws -> ExtractionResult,
                textLimit: TimeLimit, recognitionLimit: TimeLimit) {
        self.parse = parse
        self.textLimit = textLimit
        self.recognitionLimit = recognitionLimit
    }

    public func read(_ request: AttachmentTextRequest) -> AttachmentTextOutcome {
        let parse = parse
        if request.purpose == .text, request.type != "application/pdf" {
            // A Word document has no time limit at import, as before (D-495 limits PDFKit).
            return (try? parse(request)).map(AttachmentTextOutcome.finished) ?? .failed
        }
        let limit = request.purpose == .text ? textLimit : recognitionLimit
        switch limit.run({ Result { try autoreleasepool { try parse(request) } } }) {
        case .finished(.success(let result)): return .finished(result)
        case .finished(.failure): return .failed
        case .timedOut: return .timedOut
        case .tooManyStuck: return .unavailable
        }
    }
}
