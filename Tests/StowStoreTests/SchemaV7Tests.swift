import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Migration v7 (D-591): the Gmail API's queue and cursor, and `folders.provider_id`.
@Suite struct SchemaV7Tests {
    @Test func v7AddsTablesAndAColumnAndChangesNothingElse() throws {
        let test = try TestArchive()
        defer { test.remove() }
        #expect(ArchiveSchema.migrationIdentifiers.last == "v7")
        // As an archive at v6, with rows, then migrated: nothing else changes.
        try test.archive.database.write { db in
            try db.execute(sql: "DROP TABLE gmail_queue")
            try db.execute(sql: "DROP TABLE gmail_sync_state")
            try db.execute(sql: "ALTER TABLE folders DROP COLUMN provider_id")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7'")
        }
        let (before, rows) = try test.archive.database.read { db in (try V1Snapshot.digests(db), try V1Snapshot.rowCounts(db)) }
        try ArchiveSchema.migrate(test.archive.database)
        let after = try test.archive.database.read { db in
            (applied: try ArchiveSchema.migrator.appliedIdentifiers(db), digests: try V1Snapshot.digests(db),
             rows: try V1Snapshot.rowCounts(db), level: try ArchiveSchema.readerLevelSummary(db),
             columns: try db.columns(in: "folders").map(\.name))
        }
        #expect(after.applied == Set(ArchiveSchema.migrationIdentifiers))
        #expect(after.rows == rows)
        #expect(after.columns.contains("provider_id"))
        // Only `folders` gains a column; every other v1 table is as it was.
        for (table, digest) in before where table != "folders" { #expect(after.digests[table] == digest, "\(table)") }
        // The migration leaves the reader level alone; the first API sync raises it (D-591 item 5).
        #expect(after.level.hasPrefix("Reader level: needs 1"))
        #expect(ArchiveSchema.readerLevel == 3 && ArchiveSchema.gmailAPIReaderLevel == 3)
    }

    /// Read-only opens never migrate, so a newer build reads an archive at v6
    /// (status, the app's reader) before anything has written to it.
    @Test func aReadOnlyOpenOfAV6ArchiveStillReports() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try test.archive.database.write { db in
            try db.execute(sql: "DROP TABLE gmail_queue")
            try db.execute(sql: "DROP TABLE gmail_sync_state")
            try db.execute(sql: "ALTER TABLE folders DROP COLUMN provider_id")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7'")
        }
        let reader = try Archive.open(test.location, keys: test.keys, readOnly: true)
        let status = try ArchiveStatus.collect(reader)
        #expect(status.count == 1)
        _ = try Coverage.report(reader, account: test.account.id)
        _ = try ArchiveStatus.folders(reader, account: test.account.id)
        #expect(try ArchiveRemoval(archive: reader).tombstones().isEmpty)
        #expect(try reader.database.read { db in try db.tableExists("gmail_sync_state") } == false)
    }

    @Test func theFirstAPISyncRaisesTheReaderLevelAndDropsTheIMAPQueue() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = ArchiveSyncStore(archive: test.archive)
        let account = test.account.id
        _ = try await store.beginFolder(account, folder: "INBOX", uidValidity: 1, exists: 1)
        try await store.enqueue(account, folder: "INBOX", uidValidity: 1,
                                messages: [QueuedMessage(folder: "INBOX", uidValidity: 1, uid: 1, size: 5, internalDate: Date(), priority: 0)],
                                listedThrough: 1)
        #expect(try test.archive.meta("min_reader_level") == nil)
        try await store.beginGmailSync(account)
        #expect(try test.archive.meta("min_reader_level") == "3")
        #expect(try test.count("download_queue") == 0)
        #expect(try test.count("gmail_sync_state") == 1)
        // A build that reads only level 2 now refuses the archive.
        let needed = try await test.archive.database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = 'min_reader_level'").flatMap(Int.init)
        }
        #expect((needed ?? 1) > ArchiveSchema.importedMailReaderLevel)
    }

    @Test func theQueueOrdersByPriorityThenDateAndCountsFailuresOncePerRun() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = ArchiveSyncStore(archive: test.archive)
        let account = test.account.id
        try await store.beginGmailSync(account)
        let day: (Double) -> Date = { Date(timeIntervalSince1970: 1_700_000_000 + $0 * 86_400) }
        #expect(try await store.enqueueGmail(account, [
            GmailQueuedMessage(gmailID: 1, size: 100, internalDate: day(3), priority: 2),
            GmailQueuedMessage(gmailID: 2, size: 100, internalDate: day(2)),
            GmailQueuedMessage(gmailID: UInt64.max, threadID: UInt64.max, size: 100, internalDate: day(1)),
        ]) == 3)
        #expect(try await store.enqueueGmail(account, [GmailQueuedMessage(gmailID: 2, size: 1)]) == 0)
        let next = try await store.nextGmailDownloads(account, runID: "r1", maxMessages: 10, maxBytes: 10_000)
        #expect(next.map(\.gmailID) == [UInt64.max, 2, 1])
        #expect(next.first?.threadID == UInt64.max)
        // The byte cap, but never an empty batch.
        #expect(try await store.nextGmailDownloads(account, runID: "r1", maxMessages: 10, maxBytes: 1).count == 1)
        #expect(try await store.queueTotals(account) == QueueTotals(queued: 3, queuedBytes: 300, unfetchable: 0))

        // Twice in one run is one attempt; three runs record it (D-115).
        for run in ["r1", "r1", "r2"] {
            #expect(try await store.recordGmailFailedAttempt(account, runID: run, ids: [2], threshold: 3).isEmpty)
        }
        #expect(try await store.nextGmailDownloads(account, runID: "r2", maxMessages: 10, maxBytes: 10_000).map(\.gmailID) == [UInt64.max, 1])
        #expect(try await store.recordGmailFailedAttempt(account, runID: "r3", ids: [2], threshold: 3) == [2])
        #expect(try await store.queueTotals(account) == QueueTotals(queued: 2, queuedBytes: 200, unfetchable: 1))

        try await store.gmailVanishedBeforeDownload(account, ids: [1])
        #expect(try await store.queueTotals(account).queued == 1)
    }
}
