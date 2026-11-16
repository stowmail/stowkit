import CoreGraphics
import os
import StowCore
import StowExtraction
@testable import StowStore
@testable import StowSearch

// The engine takes the attachment reader from its caller (security review L-2). These tests
// use the command-line tool's, Apple's parsers in this process, through the calls they made
// before the seam, so the tests themselves did not change (D-821).

extension TextExtractor {
    init() { self.init(reader: LocalTextReader()) }
}

extension Importer {
    convenience init(archive: Archive, extractText: Bool = true, classifier: RuleClassifier? = nil) {
        self.init(archive: archive, reader: LocalTextReader(), extractText: extractText, classifier: classifier)
    }
}

extension ArchiveSyncStore {
    convenience init(archive: Archive) {
        self.init(archive: archive, importer: Importer(archive: archive))
    }
}

extension OCRQueue {
    convenience init(archive: Archive) {
        self.init(archive: archive, reader: LocalTextReader())
    }

    /// The real decoding and page rendering with a stand-in for Vision, a time limit with its
    /// own count, and a version, as the queue's own test initialiser took before the seam.
    convenience init(archive: Archive, recogniser: @escaping @Sendable (CGImage) throws -> String,
                     limit: TimeLimit = TimeLimit(limit: .seconds(60), maximumAbandoned: 1, abandoned: OSAllocatedUnfairLock(initialState: 0)),
                     version: Int = OCRQueue.version) {
        let reader = InProcessTextReader(
            parse: { request in
                let text = try AttachmentParsers.recognise(request.data, mimeType: request.type, recogniser: recogniser)
                return ExtractionResult(status: .ocrDone, text: text, method: .ocr)
            },
            textLimit: limit, recognitionLimit: limit)
        self.init(archive: archive, reader: reader, version: version)
    }
}
