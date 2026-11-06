import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Importing mbox files (briefs/mbox-import.md steps 3 to 6, D-562 to D-567),
/// on synthetic Takeout files only (D-018).
@Suite(.serialized) struct MboxImportTests {
    let imported = Account(id: AccountID(rawValue: "00000000-0000-4000-8000-0000000000a1"), provider: .imported,
                           email: "closed@example.com", displayName: "Closed")

    func writeFile(_ data: Data, name: String = "Takeout.mbox") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stow-mbox-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    func importer(_ test: TestArchive) -> MboxImporter {
        MboxImporter(archive: test.archive, importer: Importer(archive: test.archive))
    }

    // MARK: Step 3: batches and resume

    @Test func aTakeoutImportsIntoAnImportOnlyAccountByteForByte() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try test.archive.register(imported)
        let messages = SyntheticTakeout.messages(count: 14)
        let url = try writeFile(SyntheticTakeout.mbox(messages))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try test.archive.meta("min_reader_level") == nil)

        let report = try importer(test).run(url, account: imported.id)

        #expect(report.batch.messagesRead == 14)
        #expect(report.batch.imported == 14)
        #expect(report.batch.duplicates == 0 && report.batch.failed == 0)
        #expect(report.batch.finishedAt != nil)
        #expect(report.batch.committedOffset == Int64(try Data(contentsOf: url).count))
        #expect(try test.count("messages", "origin = 'imported' AND import_batch_id = \(report.batch.id)") == 14)
        #expect(try test.archive.meta("min_reader_level") == "2")
        let rows = try test.archive.database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, internal_date, thread_key, gmail_thrid, gmail_msgid, source_state FROM messages ORDER BY id")
        }
        for (index, row) in rows.enumerated() {
            let message = messages[index]
            #expect(try test.archive.rawMessage(row["id"]) == message.stored, "message \(index)")
            #expect(row["internal_date"] as Int64 == Int64(message.date.timeIntervalSince1970))
            #expect(row["thread_key"] as String == "g:\(message.threadID)")
            #expect(row["gmail_thrid"] as Int64 == Int64(bitPattern: message.threadID))
            #expect((row["gmail_msgid"] as Int64?) == nil)
        }
        // D-566: system labels as Gmail sync names them; Takeout's markers dropped; Spam and Trash as states.
        func labels(_ index: Int) throws -> Set<String> {
            Set(try test.archive.database.read { db in
                try String.fetchAll(db, sql: """
                    SELECT f.name FROM message_folders mf JOIN folders f ON f.id = mf.folder_id WHERE mf.message_id = ? AND f.kind = 'label'
                    """, arguments: [rows[index]["id"] as Int64])
            })
        }
        #expect(try labels(0) == ["\\Inbox"])
        #expect(try labels(1) == ["\\Sent"])
        #expect(try labels(2) == ["\\Inbox", "\\Starred", "\\Important"])
        #expect(try labels(3) == ["Projects/Alpha"])
        #expect(try labels(4).isEmpty && rows[4]["source_state"] as String == "spam")
        #expect(try labels(5).isEmpty && rows[5]["source_state"] as String == "trashed")
        #expect(try labels(6) == ["\\Inbox"])
        #expect(try test.count("message_folders mf JOIN folders f ON f.id = mf.folder_id", "f.kind = 'folder'") == 0)
        // Every imported message passes verify, like any other.
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
    }

    @Test func theSameFileTwiceImportsNothingTheSecondTime() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try test.archive.register(imported)
        let url = try writeFile(SyntheticTakeout.mbox(SyntheticTakeout.messages(count: 6)))
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try importer(test).run(url, account: imported.id)

        let again = try importer(test).run(url, account: imported.id)

        #expect(again.alreadyImported)
        #expect(again.batch.imported == 6)
        #expect(try test.count("messages") == 6)
        #expect(try test.count("import_batches") == 1)
    }

    @Test func stoppingMidFileAndRunningAgainGivesNoDuplicatesAndNoGaps() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try test.archive.register(imported)
        let messages = SyntheticTakeout.messages(count: 12)
        let url = try writeFile(SyntheticTakeout.mbox(messages))
        defer { try? FileManager.default.removeItem(at: url) }
        var first = importer(test)
        first.stopAfter = 5

        let stopped = try first.run(url, account: imported.id)
        #expect(stopped.batch.finishedAt == nil)
        let unfinished = try test.archive.database.read { db in try MboxImporter.unfinished(db, account: imported.id) }
        #expect(unfinished.map(\.messagesRead) == [5])
        #expect(unfinished.first?.committedOffset == stopped.batch.committedOffset)

        let resumed = try importer(test).run(url, account: imported.id)

        #expect(resumed.resumedFrom == stopped.batch.committedOffset)
        #expect(resumed.batch.messagesRead == 12)
        #expect(resumed.batch.imported == 12 && resumed.batch.duplicates == 0)
        #expect(resumed.batch.finishedAt != nil)
        let stored = try test.archive.database.read { db in try StoredMessageID.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }
        #expect(try stored.map { try test.archive.rawMessage($0) } == messages.map(\.stored))
        #expect(try test.count("import_batches") == 1)
    }

    @Test func aChangedFileIsRefusedUntilStartedOver() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try test.archive.register(imported)
        let messages = SyntheticTakeout.messages(count: 8)
        let url = try writeFile(SyntheticTakeout.mbox(Array(messages.prefix(6))))
        defer { try? FileManager.default.removeItem(at: url) }
        var first = importer(test)
        first.stopAfter = 3
        _ = try first.run(url, account: imported.id)
        try SyntheticTakeout.mbox(messages).write(to: url)

        #expect(throws: MboxImportError.fileChanged(url.standardizedFileURL.path)) {
            try importer(test).run(url, account: imported.id)
        }
        let restarted = try importer(test).run(url, account: imported.id, startOver: true)

        #expect(restarted.batch.messagesRead == 8)
        #expect(restarted.batch.imported == 5)
        #expect(restarted.duplicates == [.sameBytes: 3])
        #expect(try test.count("messages") == 8)
        #expect(try test.count("import_batches", "finished_at IS NULL") == 0)
    }

    @Test func messagesThatCannotBeImportedAreCountedByReasonWithOffsetsOnly() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try test.archive.register(imported)
        var file = SyntheticTakeout.mbox(SyntheticTakeout.messages(count: 2))
        file.append(Data("From 1@xxx Mon Sep 18 10:12:13 +0000 2023\r\n\r\n".utf8))   // empty
        file.append(Data("From 2@xxx Mon Sep 18 10:12:14 +0000 2023\r\nSubject: cut".utf8))   // cut short
        let url = try writeFile(file)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try importer(test).run(url, account: imported.id)

        #expect(report.batch.imported == 2 && report.batch.failed == 2)
        #expect(report.failures == ["empty": 1, "cut_short": 1])
        let reasons = try test.archive.database.read { db in try String.fetchAll(db, sql: "SELECT reason FROM import_failures ORDER BY file_offset") }
        #expect(reasons == ["empty", "cut_short"])
    }

    // MARK: Step 4: duplicates (D-565)

    /// A message as IMAP gives it: Gmail's bytes without Takeout's two headers.
    func syncCopy(_ test: TestArchive, _ message: SyntheticTakeout.Message, uid: UInt32) throws -> StoredMessageID {
        guard case .imported(let id) = try Importer(archive: test.archive).importMessage(test.raw(message.body, folder: "INBOX", uid: uid)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return id
    }

    @Test func takeoutAndIMAPCopiesMatchButMessagesSharingAMessageIDDoNot() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let messages = SyntheticTakeout.messages(count: 4)
        let synced = try syncCopy(test, messages[0], uid: 1)
        _ = try syncCopy(test, messages[3], uid: 2)
        // Same Message-ID as message 1's, different words: a different message.
        var other = messages[1]
        other.body = Data(String(decoding: other.body, as: UTF8.self).replacingOccurrences(of: "Hello Sam", with: "Dear Sam").utf8)
        _ = try syncCopy(test, other, uid: 3)
        let before = try test.archive.database.read { db in try V1Snapshot.digests(db, excluding: []) }
        let url = try writeFile(SyntheticTakeout.mbox(messages))
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try importer(test).run(url, account: test.account.id)

        #expect(report.duplicates == [.sameMessage: 2])
        #expect(report.batch.imported == 2)
        #expect(try test.count("messages", "origin = 'imported'") == 2)
        #expect(try test.count("messages", "rfc822_message_id = 'takeout-1-1@example.org'") == 2)
        // The synced copies are untouched.
        #expect(try test.archive.database.read { db in try String.fetchOne(db, sql: "SELECT origin FROM messages WHERE id = ?", arguments: [synced]) } == "synced")
        let after = try test.archive.database.read { db in try V1Snapshot.digests(db, excluding: []) }
        #expect(after["accounts"] == before["accounts"] && after["tombstones"] == before["tombstones"])
    }

    @Test func aMessageRemovedEarlierIsNotImportedAgain() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let messages = SyntheticTakeout.messages(count: 3)
        try test.archive.database.write { db in
            try db.execute(sql: """
                INSERT INTO tombstones (account_id, raw_hash, rfc822_message_id, internal_date, size, reason, removed_at)
                VALUES (?, randomblob(32), 'takeout-1-1@example.org', ?, 1, 'user', 0)
                """, arguments: [test.account.id.rawValue, Int(messages[1].date.timeIntervalSince1970) + 3_600])
        }
        let url = try writeFile(SyntheticTakeout.mbox(messages))
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try importer(test).run(url, account: test.account.id)

        #expect(report.duplicates == [.removedEarlier: 1])
        #expect(try test.count("messages") == 2)
    }

    // MARK: D-562: the first server copy makes it synced

    @Test func aServerCopyOfTheSameBytesTurnsAnImportedMessageSynced() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let messages = SyntheticTakeout.messages(count: 2)
        let url = try writeFile(SyntheticTakeout.mbox(messages))
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try importer(test).run(url, account: test.account.id)

        let outcome = try Importer(archive: test.archive).importMessage(test.raw(messages[0].stored, folder: "INBOX", uid: 9))

        guard case .linked(let id) = outcome else { Issue.record("expected linked, got \(outcome)"); return }
        let row = try test.archive.database.read { db in try Row.fetchOne(db, sql: "SELECT origin, import_batch_id FROM messages WHERE id = ?", arguments: [id]) }
        #expect(row?["origin"] as String? == "synced")
        #expect((row?["import_batch_id"] as Int64?) == nil)
        #expect(try test.count("messages", "origin = 'imported'") == 1)
    }

    // MARK: D-567: what imported mail is left out of

    @Test func importedMailIsNotSafeToDeleteNorLookedForAsVanished() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let messages = SyntheticTakeout.messages(count: 4)
        _ = try syncCopy(test, messages[0], uid: 1)
        let url = try writeFile(SyntheticTakeout.mbox(Array(messages.dropFirst())))
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try importer(test).run(url, account: test.account.id)

        let (count, _) = try await test.archive.database.read { db in
            try Coverage.presentBefore(db, account: test.account.id, date: Date(timeIntervalSince1970: 4_000_000_000))
        }
        #expect(count == 1)
        let vanished = try await ArchiveSyncStore(archive: test.archive).unclassifiedVanished(test.account.id)
        #expect(vanished.isEmpty)
        let status = try ArchiveStatus.collect(test.archive).first { $0.account.account.id == test.account.id }
        #expect(status?.importedMessages == 3)
        // Message 4 (index 4 of the cycle) would be spam; none here, so no "changed in the mailbox" count from imports.
        #expect(status?.sourceStates.isEmpty == true)
    }

    @Test func anArchiveWithoutImportsStaysAtReaderLevelOne() throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try syncCopy(test, SyntheticTakeout.messages(count: 1)[0], uid: 1)
        #expect(try test.archive.meta("min_reader_level") == nil)
        #expect(ArchiveSchema.importedMailReaderLevel == 2)
    }

    // MARK: Step 5: Takeout's headers (D-566)

    @Test func takeoutLabelsAreReadWithQuotesAndEncodedWords() {
        let bytes = Data("""
            X-GM-THRID: 1780000000000000123\r
            X-Gmail-Labels: Inbox,"Clients, 2024",=?UTF-8?Q?R=C3=A9sum=C3=A9s?=,Opened,Category Social,Trash,Spam\r
            Subject: x\r
            \r
            body\r

            """.utf8)
        let headers = TakeoutHeaders(bytes)
        #expect(headers.labels == ["\\Inbox", "Clients, 2024", "Résumés"])
        #expect(headers.threadID == 1_780_000_000_000_000_123)
        #expect(headers.sourceState == .spam)
        let plain = TakeoutHeaders(Data("Subject: x\r\n\r\nbody\r\n".utf8))
        #expect(plain.labels.isEmpty && plain.threadID == nil && plain.sourceState == .present)
    }
}
