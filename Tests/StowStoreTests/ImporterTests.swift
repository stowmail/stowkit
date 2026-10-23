import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

@Suite(.serialized) struct ImporterTests {
    @Test func everyFixtureImports() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let summary = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        #expect(summary.imported == 25)
        #expect(summary.failed == 0)
        #expect(try test.count("messages") == 25)
        #expect(try test.count("messages_fts") == 25)
        #expect(try test.count("messages", "parse_status = 'degraded'") == 2)
        #expect(try test.count("messages", "parse_status = 'failed'") == 0)
        let warnings = try await test.archive.database.read { db in
            try String.fetchAll(db, sql: "SELECT parse_warnings FROM messages WHERE parse_warnings IS NOT NULL")
        }
        #expect(warnings.sorted() == ["[\"malformed Date\"]", "[\"missing Message-ID\"]"])
    }

    @Test func importingTwiceChangesNothing() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let source = MemorySource(try test.fixtureMessages())
        _ = try await Importer(archive: test.archive).importAll(from: source)
        let before = try snapshot(test)
        let filesBefore = test.files(in: test.location.root).map(\.path).sorted()

        let second = try await Importer(archive: test.archive).importAll(from: source)
        #expect(second.alreadyPresent == 25)
        #expect(second.imported == 0)
        #expect(try snapshot(test) == before)
        #expect(test.files(in: test.location.root).map(\.path).sorted() == filesBefore)

        // Even calling importMessage directly on a known copy is a no-op.
        let raw = try test.fixtureMessages()[0]
        #expect(try Importer(archive: test.archive).importMessage(raw) == .alreadyPresent)
        #expect(try snapshot(test) == before)
    }

    /// Every row of every table, as text, for exact before-and-after comparison.
    func snapshot(_ test: TestArchive) throws -> [String] {
        try test.archive.database.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'messages_fts_%' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
            return try tables.flatMap { table in
                try Row.fetchAll(db, sql: "SELECT * FROM \(table)").map { "\(table): \($0)" }.sorted()
            }
        }
    }

    @Test func samePDFInTwoMessagesIsStoredOnce() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let importer = Importer(archive: test.archive)
        _ = try importer.importMessage(test.raw(try Fixtures.data("06-"), uid: 1))
        let filesAfterFirst = test.files(in: test.location.attachmentsDirectory).count
        _ = try importer.importMessage(test.raw(try Fixtures.data("07-"), uid: 2))
        #expect(try test.count("attachments") == 1)
        #expect(try test.count("message_attachments") == 2)
        #expect(test.files(in: test.location.attachmentsDirectory).count == filesAfterFirst)
        let names = try await test.archive.database.read { db in
            try String.fetchAll(db, sql: "SELECT filename FROM message_attachments ORDER BY message_id")
        }
        #expect(names == ["quarterly-report.pdf", "Q3 report (copy).pdf"])
    }

    @Test func sameMessageInTwoFoldersIsOneRowWithTwoLocations() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let importer = Importer(archive: test.archive)
        let data = try Fixtures.data("01-")
        guard case .imported(let id) = try importer.importMessage(test.raw(data, folder: "INBOX", uid: 1)) else {
            Issue.record("first import should store the message")
            return
        }
        #expect(try importer.importMessage(test.raw(data, folder: "Archive/2025", uid: 7)) == .linked(id))
        #expect(try test.count("messages") == 1)
        #expect(try test.count("message_folders") == 2)
    }

    @Test func gmailLabelsBecomeLabelFolders() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let raw = test.raw(try Fixtures.data("01-"), folder: "[Gmail]/All Mail", uid: 1, labels: ["\\Inbox", "Walks"])
        _ = try Importer(archive: test.archive).importMessage(raw)
        #expect(try test.count("folders", "kind = 'label'") == 2)
        #expect(try test.count("message_folders", "uid IS NULL") == 2)
    }

    @Test func unknownAccountIsRefused() throws {
        let test = try TestArchive()
        defer { test.remove() }
        var raw = test.raw(try Fixtures.data("01-"), uid: 1)
        raw = RawMessage(key: RawMessageKey(accountID: AccountID(rawValue: "other"), folder: "INBOX", uidValidity: 1, uid: 1),
                         internalDate: raw.internalDate, size: raw.size, bytes: raw.bytes)
        #expect(throws: ImportError.self) { try Importer(archive: test.archive).importMessage(raw) }
    }

    @Test func addressesThreadsAndBodiesAreStored() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        #expect(try test.count("message_addresses", "role = 'delivered_to'") == 25)
        #expect(try test.count("message_addresses", "role IN ('to', 'cc')") >= 60)
        #expect(try test.count("messages", "thread_key LIKE 'm:thread-1-reference@%'") == 1)
        #expect(try test.count("message_bodies") == 25)
        #expect(try test.count("messages", "has_attachments = 1") == 8)  // inline logo does not count
    }

    @Test func rawMessagesRoundTrip() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let importer = Importer(archive: test.archive)
        for raw in try test.fixtureMessages() {
            guard case .imported(let id) = try importer.importMessage(raw) else { continue }
            #expect(try test.archive.rawMessage(id) == raw.bytes)
        }
    }

    // MARK: Extraction at import

    func attachmentText(_ test: TestArchive, contains keyword: String) throws -> Bool {
        try test.archive.database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM attachment_text WHERE text LIKE ?)",
                              arguments: ["%\(keyword)%"])!
        }
    }

    @Test func pdfDocxAndTextAttachmentsAreExtractedAndScansQueued() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        #expect(try attachmentText(test, contains: "PERIWINKLE-LEDGER-4471"))
        #expect(try attachmentText(test, contains: "MARIGOLD-MINUTES-9031"))
        #expect(try attachmentText(test, contains: "Lifejackets"))
        #expect(try test.count("attachments", "text_status = 'ocr_pending'") == 1)
        #expect(try test.count("attachments", "text_status = 'none' AND mime_type = 'image/png'") == 1)
    }

    @Test func importWithoutExtractionStillIndexesTheRest() throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try Importer(archive: test.archive, extractText: false).importMessage(test.raw(try Fixtures.data("06-"), uid: 1))
        #expect(try test.count("attachment_text") == 0)
        #expect(try test.count("messages_fts") == 1)
    }
}
