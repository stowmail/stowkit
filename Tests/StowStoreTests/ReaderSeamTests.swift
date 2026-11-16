import Foundation
import GRDB
import os
import StowCore
import Testing
@testable import StowStore

/// Security review L-2: import reaches Apple's parsers only through the reader seam, and
/// a reader that fails, times out, cannot be reached or answers nothing never stops the
/// next message (the outcomes the Mac app's helper can give, D-824).
@Suite struct ReaderSeamTests {
    /// Answers every request with one outcome and remembers what it was asked.
    final class FakeReader: AttachmentTextReading, @unchecked Sendable {
        let outcome: AttachmentTextOutcome
        private let lock = NSLock()
        private var seen: [AttachmentTextRequest] = []

        init(_ outcome: AttachmentTextOutcome) { self.outcome = outcome }

        var requests: [AttachmentTextRequest] { lock.withLock { seen } }

        func read(_ request: AttachmentTextRequest) -> AttachmentTextOutcome {
            lock.withLock { seen.append(request) }
            return outcome
        }
    }

    static func fixture(_ prefix: String) throws -> Data {
        let name = try FileManager.default.contentsOfDirectory(atPath: Fixtures.directory.path).first { $0.hasPrefix(prefix) }!
        return try Data(contentsOf: Fixtures.directory.appendingPathComponent(name))
    }

    func statuses(_ test: TestArchive) throws -> [String: (status: String, failed: Int?)] {
        try test.archive.database.read { db in
            var found: [String: (String, Int?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT mime_type, text_status, text_failed_version FROM attachments") {
                found[row["mime_type"]] = (row["text_status"], row["text_failed_version"])
            }
            return found
        }
    }

    @Test(arguments: [AttachmentTextOutcome.failed, .timedOut, .unavailable])
    func aReaderThatDoesNotAnswerMarksTheAttachmentAndImportGoesOn(_ outcome: AttachmentTextOutcome) throws {
        let test = try TestArchive()
        defer { test.remove() }
        let reader = FakeReader(outcome)
        let importer = Importer(archive: test.archive, reader: reader)
        _ = try importer.importMessage(test.raw(try Self.fixture("06-"), uid: 1))
        _ = try importer.importMessage(test.raw(try Self.fixture("09-"), uid: 2))
        _ = try importer.importMessage(test.raw(try Self.fixture("01-"), uid: 3))

        #expect(try test.count("messages") == 3)
        let found = try statuses(test)
        // Marked as unreadable with this extractor's version (D-481), so a newer one tries again.
        #expect(found["application/pdf"]?.status == "unsupported")
        #expect(found["application/pdf"]?.failed == TextExtractor.version)
        #expect(found[TextExtractor.docxType]?.status == "unsupported")
        #expect(found[TextExtractor.docxType]?.failed == TextExtractor.version)
        #expect(reader.requests.map(\.type) == ["application/pdf", TextExtractor.docxType])
        #expect(reader.requests.allSatisfy { $0.purpose == .text && !$0.data.isEmpty })
    }

    @Test func aReaderThatAnswersNothingStoresNoTextAndNoMark() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let importer = Importer(archive: test.archive, reader: FakeReader(.finished(.none)))
        _ = try importer.importMessage(test.raw(try Self.fixture("06-"), uid: 1))
        _ = try importer.importMessage(test.raw(try Self.fixture("01-"), uid: 2))
        #expect(try test.count("messages") == 2)
        #expect(try statuses(test)["application/pdf"]?.status == "none")
        #expect(try statuses(test)["application/pdf"]?.failed == nil)
        #expect(try test.count("attachment_text") == 0)
    }

    @Test func textAttachmentsAndImagesNeverReachTheReader() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let reader = FakeReader(.failed)
        let importer = Importer(archive: test.archive, reader: reader)
        // 05 to 09 carry PDFs and a Word document; every other fixture holds text, HTML, an image or a calendar.
        for (index, file) in try Fixtures.allFiles().enumerated() where !["05-", "06-", "07-", "08-", "09-"].contains(String(file.prefix(3))) {
            _ = try importer.importMessage(test.raw(try Data(contentsOf: Fixtures.directory.appendingPathComponent(file)), uid: UInt32(index + 1)))
        }
        #expect(reader.requests.isEmpty)
    }

    @Test func theReadersAnswerIsWhatIsStored() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let importer = Importer(archive: test.archive, reader: FakeReader(.finished(.text("Shelduck invoice", method: .pdfkit))))
        _ = try importer.importMessage(test.raw(try Self.fixture("06-"), uid: 1))
        let text = try test.archive.database.read { db in try String.fetchOne(db, sql: "SELECT text FROM attachment_text") }
        #expect(text == "Shelduck invoice")
    }
}
