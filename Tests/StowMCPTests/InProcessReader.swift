import StowCore
import StowExtraction
@testable import StowStore

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
