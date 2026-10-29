import Foundation
import GRDB
import os
import StowCore
import Testing
@testable import StowStore

/// D-481 with the schema (security sweep 1, step 7; D-501, D-502): an email
/// whose reading never finishes is counted before each try, stored whole and
/// marked after three, and read again only by a newer parser or extractor.
@Suite(.serialized, .timeLimit(.minutes(1))) struct UnreadTextTests {
    static func message(_ n: Int) -> Data {
        Data("""
            From: Sam <sam@example.org>\r
            To: sam@example.com\r
            Subject: Note \(n) heronsfield\r
            Date: Mon, 1 Sep 2025 10:00:00 +0000\r
            Message-ID: <note-\(n)@example.org>\r
            \r
            Body \(n) kingfisherwood\r

            """.utf8)
    }

    /// A parser stand-in that does not return until released. To the archive a
    /// killed import and a hung one look the same: a try recorded, nothing after it.
    final class StuckParser: Sendable {
        let gate = DispatchSemaphore(value: 0)
        let entered = OSAllocatedUnfairLock(initialState: 0)
        var parse: @Sendable (Data) -> ParsedMessage {
            { [self] data in
                entered.withLock { $0 += 1 }
                gate.wait()
                return MIMEParser().parse(data)
            }
        }
        func release(_ count: Int) { for _ in 0..<count { gate.signal() } }
    }

    /// A parser stand-in that counts its calls and parses normally.
    final class CountingParser: Sendable {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var parse: @Sendable (Data) -> ParsedMessage { { [self] data in calls.withLock { $0 += 1 }; return MIMEParser().parse(data) } }
        var count: Int { calls.withLock { $0 } }
    }

    static func shortLimit() -> TimeLimit {
        TimeLimit(limit: .milliseconds(200), maximumAbandoned: 8, abandoned: OSAllocatedUnfairLock(initialState: 0))
    }

    static func longLimit() -> TimeLimit {
        TimeLimit(limit: .seconds(60), maximumAbandoned: 8, abandoned: OSAllocatedUnfairLock(initialState: 0))
    }

    static func waitUntil(_ condition: () throws -> Bool) rethrows {
        let deadline = Date().addingTimeInterval(10)
        while try !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    func importAttempts(_ test: TestArchive, uid: UInt32) throws -> Int? {
        try test.archive.database.read { db in
            try Int.fetchOne(db, sql: "SELECT import_attempts FROM download_queue WHERE uid = ?", arguments: [Int64(uid)])
        }
    }

    // MARK: - Import

    @Test func twoKillsAndAHangThenTheMessageIsStoredWholeAndMarked() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let account = test.account.id
        let setup = ArchiveSyncStore(archive: test.archive)
        try await setup.recordFolders(account, [SyncFolder(name: "INBOX")])
        _ = try await setup.beginFolder(account, folder: "INBOX", uidValidity: 1, exists: 2)
        try await setup.enqueue(account, folder: "INBOX", uidValidity: 1, messages: [1, 2].map {
            QueuedMessage(folder: "INBOX", uidValidity: 1, uid: $0, size: 300, internalDate: Date(timeIntervalSince1970: 1_756_720_800))
        }, listedThrough: 2)
        let hostile = test.raw(Self.message(1), uid: 1)
        let stuck = StuckParser()
        let finished = OSAllocatedUnfairLock(initialState: 0)

        // Twice the process is killed while reading it: each run on a thread
        // left stuck, then a new store and importer, as after a restart.
        for kill in 1...2 {
            let store = ArchiveSyncStore(archive: test.archive, importer: Importer(
                archive: test.archive, extractor: TextExtractor(), parse: stuck.parse, preparation: Self.longLimit()))
            Thread.detachNewThread {
                _ = try? store.store(hostile)
                finished.withLock { $0 += 1 }
            }
            Self.waitUntil { stuck.entered.withLock { $0 } == kill }
            #expect(try importAttempts(test, uid: 1) == kill)
        }

        // The third time it hangs: the time limit gives up, nothing is stored, the try stays counted.
        let hanging = ArchiveSyncStore(archive: test.archive, importer: Importer(
            archive: test.archive, extractor: TextExtractor(), parse: stuck.parse, preparation: Self.shortLimit()))
        #expect(throws: ImportError.timedOut(hostile.key)) { try hanging.store(hostile) }
        #expect(try importAttempts(test, uid: 1) == 3)
        #expect(try test.count("messages") == 0)

        // The fourth run stores it whole without parsing it, and the message behind it is archived.
        let parser = CountingParser()
        let store = ArchiveSyncStore(archive: test.archive, importer: Importer(
            archive: test.archive, extractor: TextExtractor(), parse: parser.parse))
        try store.store(hostile)
        #expect(parser.count == 0)
        try store.store(test.raw(Self.message(2), uid: 2))
        #expect(parser.count == 1)
        #expect(try test.count("download_queue") == 0)

        #expect(try test.count("messages", """
            text_state = 'incomplete' AND text_marked_version = \(MIMEParser.version) AND text_attempts = 0
            AND parse_status = 'failed' AND raw_state = 'full' AND subject IS NULL
            """) == 1)
        #expect(try test.count("messages", "text_state = 'complete' AND subject = 'Note 2 heronsfield'") == 1)

        // Stored exactly as received, exports byte for byte, and verify calls the archive intact.
        let id = try #require(try await test.archive.database.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM messages WHERE text_state = 'incomplete'")
        })
        #expect(try test.archive.rawMessage(id) == hostile.bytes)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stow-eml-\(UUID().uuidString).eml")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        _ = try EmlExport.write(test.archive, message: id, to: handle)
        try handle.close()
        #expect(try Data(contentsOf: file) == hostile.bytes)
        let report = try ArchiveVerifier(archive: test.archive).run()
        #expect(report.isClean && report.rebuilt == 2)
        #expect(try UnreadText.collect(test.archive) == UnreadText(messages: 1, messagesWithUnreadAttachments: 0, total: 1))

        // The killed runs finishing late change nothing: the message is stored once, still marked.
        stuck.release(3)
        Self.waitUntil { finished.withLock { $0 } == 2 }
        #expect(finished.withLock { $0 } == 2)
        #expect(try test.count("messages") == 2)
        #expect(try test.count("messages", "text_state = 'incomplete'") == 1)
    }

    @Test func anImportThatFailsWithAnErrorIsNotCountedAsUnfinished() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let account = test.account.id
        let store = ArchiveSyncStore(archive: test.archive, importer: Importer(
            archive: test.archive, extractor: TextExtractor(),
            preparation: TimeLimit(limit: .seconds(5), maximumAbandoned: 0, abandoned: OSAllocatedUnfairLock(initialState: 0))))
        try await store.recordFolders(account, [SyncFolder(name: "INBOX")])
        _ = try await store.beginFolder(account, folder: "INBOX", uidValidity: 1, exists: 1)
        try await store.enqueue(account, folder: "INBOX", uidValidity: 1,
                                messages: [QueuedMessage(folder: "INBOX", uidValidity: 1, uid: 1, size: 300)], listedThrough: 1)
        // No room for another reading in this process: not the message's fault.
        #expect(throws: ImportError.tooManyStuck) { try store.store(test.raw(Self.message(1), uid: 1)) }
        #expect(try importAttempts(test, uid: 1) == 0)
    }

    // MARK: - Retry after an update

    @Test func aMarkedMessageIsReadAgainOnlyByANewerParser() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let raw = test.raw(Self.message(1), uid: 1)
        _ = try Importer(archive: test.archive, extractor: TextExtractor(), parserVersion: 1).storeUnread(raw)
        #expect(try test.count("messages_fts", "messages_fts MATCH 'kingfisherwood'") == 0)

        // Same version: not tried.
        let parser = CountingParser()
        let sameVersion = Importer(archive: test.archive, extractor: TextExtractor(), parse: parser.parse, parserVersion: 1)
        #expect(try sameVersion.retryMarkedMessages() == TextRetrySummary())
        #expect(parser.count == 0)

        // A newer parser: one round, and the message is read in full.
        let newer = Importer(archive: test.archive, extractor: TextExtractor(), parse: parser.parse, parserVersion: 2)
        #expect(try newer.retryMarkedMessages() == TextRetrySummary(read: 1))
        #expect(parser.count == 1)
        #expect(try test.count("messages", """
            text_state = 'complete' AND text_marked_version IS NULL AND text_attempts = 0 AND parse_status = 'ok'
            AND parser_version = 2 AND subject = 'Note 1 heronsfield' AND from_address_id IS NOT NULL
            """) == 1)
        #expect(try test.count("messages_fts", "messages_fts MATCH 'kingfisherwood'") == 1)
        #expect(try test.archive.rawMessage(1) == raw.bytes)
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)

        // Nothing left to read again.
        #expect(try newer.retryMarkedMessages() == TextRetrySummary())
        #expect(parser.count == 1)
    }

    @Test func aRetryThatNeverFinishesIsMarkedWithTheNewVersionAfterThreeTries() throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try Importer(archive: test.archive, extractor: TextExtractor(), parserVersion: 1).storeUnread(test.raw(Self.message(1), uid: 1))
        let stuck = StuckParser()
        defer { stuck.release(3) }
        for attempt in 1...3 {
            let hanging = Importer(archive: test.archive, extractor: TextExtractor(), parse: stuck.parse, parserVersion: 2,
                                   preparation: Self.shortLimit())
            #expect(throws: ImportError.retryTimedOut(1)) { try hanging.retryMarkedMessages() }
            #expect(try test.count("messages", "text_attempts = \(attempt) AND text_marked_version = 1") == 1)
        }
        // Tries used up: marked with version 2 without reading it, and version 2 leaves it alone from now on.
        let parser = CountingParser()
        let version2 = Importer(archive: test.archive, extractor: TextExtractor(), parse: parser.parse, parserVersion: 2)
        #expect(try version2.retryMarkedMessages() == TextRetrySummary(marked: 1))
        #expect(try version2.retryMarkedMessages() == TextRetrySummary())
        #expect(parser.count == 0)
        #expect(try test.count("messages", "text_state = 'incomplete' AND text_marked_version = 2 AND text_attempts = 0") == 1)
        // A later version gets its own round.
        let version3 = Importer(archive: test.archive, extractor: TextExtractor(), parse: parser.parse, parserVersion: 3)
        #expect(try version3.retryMarkedMessages() == TextRetrySummary(read: 1))
        #expect(parser.count == 1)
    }

    @Test func aPDFThatTimedOutIsMarkedAndReadAgainOnlyByANewerExtractor() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let hang = TextBoundsTests.Hang()
        defer { hang.release(1) }
        let stuckPDF = TextExtractor(pdfText: hang.extract, pdfLimit: .milliseconds(200))
        let raw = test.raw(TextBoundsTests.pdfMessage(), uid: 1)
        guard case .imported = try Importer(archive: test.archive, extractor: stuckPDF, extractorVersion: 1).importMessage(raw) else {
            Issue.record("not imported")
            return
        }
        // Stored, its own text read, the PDF marked as unreadable rather than "a type Stow does not read".
        #expect(try test.count("messages", "text_state = 'complete'") == 1)
        #expect(try test.count("attachments", "text_status = 'unsupported' AND text_failed_version = 1") == 1)
        #expect(try UnreadText.collect(test.archive) == UnreadText(messages: 0, messagesWithUnreadAttachments: 1, total: 1))

        let reads = OSAllocatedUnfairLock(initialState: 0)
        let working = TextExtractor(pdfText: { _ in
            reads.withLock { $0 += 1 }
            return ExtractionResult(status: .extracted, text: "Ospreymarsh invoice", method: .pdfkit)
        }, pdfLimit: .seconds(5))
        #expect(try Importer(archive: test.archive, extractor: working, extractorVersion: 1).retryUnreadAttachments() == TextRetrySummary())
        #expect(reads.withLock { $0 } == 0)

        #expect(try Importer(archive: test.archive, extractor: working, extractorVersion: 2).retryUnreadAttachments() == TextRetrySummary(read: 1))
        #expect(reads.withLock { $0 } == 1)
        #expect(try test.count("attachments", "text_status = 'extracted' AND text_failed_version IS NULL AND text_attempts = 0") == 1)
        #expect(try test.count("messages_fts", "messages_fts MATCH 'ospreymarsh'") == 1)
        #expect(try UnreadText.collect(test.archive) == UnreadText())
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
    }

    @Test func anArchiveWithoutV2HasNoMarksToCount() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in try db.execute(sql: "CREATE TABLE messages (id INTEGER PRIMARY KEY)") }
        #expect(try queue.read { db in try UnreadText.collect(db) } == nil)
    }
}
