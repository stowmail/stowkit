import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Migration v3 (D-521, D-522): the provider's DMARC result for the From domain,
/// per message, added to archives that already hold real mail. These tests cover
/// the column, its index and the upgrade; `SenderDMARCStoreTests` what writes it.
@Suite(.serialized) struct SchemaV3Tests {
    @Test func freshArchiveImportsWithAResultForEveryMessage() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        #expect(try test.count("messages") == 25)
        #expect(try test.count("messages", "sender_dmarc IS NULL") == 0)
        #expect(try pending(test.archive.database) == 0)
        let applied = try await test.archive.database.read { db in try ArchiveSchema.migrator.appliedIdentifiers(db) }
        #expect(applied == Set(ArchiveSchema.migrationIdentifiers))
        #expect(ArchiveSchema.migrationIdentifiers.contains("v3"))
    }

    @Test func onlyTheThreeResultsOrNothing() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        try await forget(test)
        for refused in ["bestguesspass", "PASS", "", "softfail"] {
            await #expect(throws: DatabaseError.self, "\(refused)") {
                try await test.archive.database.write { db in
                    try db.execute(sql: "UPDATE messages SET sender_dmarc = ? WHERE id = 1", arguments: [refused])
                }
            }
        }
        try await test.archive.database.write { db in
            for (id, value) in [(1, "pass"), (2, "fail"), (3, "none")] {
                try db.execute(sql: "UPDATE messages SET sender_dmarc = ? WHERE id = ?", arguments: [value, id])
            }
            try db.execute(sql: "UPDATE messages SET sender_dmarc = NULL WHERE id = 3")   // back to "not yet read"
        }
        #expect(try pending(test.archive.database) == 23)
    }

    /// The backfill drains the partial index: once every message has a result,
    /// the batch query returns nothing and reads nothing.
    @Test func theIndexHoldsOnlyMessagesNotYetRead() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        try await forget(test)
        var after: Int64 = 0
        var read: [Int64] = []
        while true {
            let start = after
            let batch = try await test.archive.database.read { db in
                try Int64.fetchAll(db, sql: BackfillQueries.batch, arguments: ["after": start, "limit": 10])
            }
            guard let last = batch.last else { break }
            read += batch
            after = last
            try await test.archive.database.write { db in
                try db.execute(sql: "UPDATE messages SET sender_dmarc = 'none' WHERE id IN (\(batch.map(String.init).joined(separator: ",")))")
            }
        }
        #expect(read == Array(1...25))
        #expect(try pending(test.archive.database) == 0)
        let entries = try await test.archive.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages INDEXED BY messages_dmarc_pending WHERE sender_dmarc IS NULL")!
        }
        #expect(entries == 0)
    }

    @Test func backfillQueriesUseThePartialIndex() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let plans = try test.archive.database.read { db in try BackfillQueries.plans(db) }
        BackfillQueries.expectIndexed(plans)
        for (query, plan) in zip(BackfillQueries.expected, plans) { print("v3 plan: \(query.sql)\n    \(plan)") }
    }

    /// The upgrade on a copy of an archive the size of a real one: built at v2
    /// with v2's marks and counts set on some rows, copied, and the copy migrated.
    /// Every v2 value must read back unchanged, every message must be waiting for
    /// the backfill, the v2 queries must still use their indexes, and the
    /// database, foreign keys and search index must check clean.
    ///
    /// 2,000 messages by default, so every `check.sh` and CI run covers it. For
    /// the full size (D-522 records the measured run), in a release build:
    ///
    ///     STOW_MIGRATION_MESSAGES=40000 swift test -c release -Xswiftc -enable-testing --filter SchemaV3Tests
    @Test func upgradeFromV2OnACopyOfARealSizedArchive() throws {
        let messages = Int(ProcessInfo.processInfo.environment["STOW_MIGRATION_MESSAGES"] ?? "") ?? 2_000
        let keys = TestArchive.randomKeys()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stow-v3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = folder.appendingPathComponent("v2.sqlite")
        let built = Date()
        let before: [String: Data]
        let rows: [String: Int]
        do {
            let db = try EncryptedDatabase.open(at: original, key: keys.databaseKeyData)
            try ArchiveSchema.migrator.migrate(db, upTo: "v1")
            try RealSizedArchive.fill(db, messages: messages)
            try ArchiveSchema.migrator.migrate(db, upTo: "v2")
            try RealSizedArchive.markV2(db)
            (before, rows) = try db.read { db in (try V1Snapshot.digests(db, excluding: addedInV3), try V1Snapshot.rowCounts(db)) }
            // A small last write stays in the WAL after close; copy only the main file, so write it back first.
            _ = try db.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            try db.close()
        }
        let buildSeconds = Date().timeIntervalSince(built)

        let copy = folder.appendingPathComponent("copy.sqlite")
        try FileManager.default.copyItem(at: original, to: copy)
        let fileSize = try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int ?? 0
        let db = try EncryptedDatabase.open(at: copy, key: keys.databaseKeyData)
        let started = Date()
        try ArchiveSchema.migrator.migrate(db, upTo: "v3")
        let migrateSeconds = Date().timeIntervalSince(started)

        let after = try db.read { db in
            (applied: try ArchiveSchema.migrator.appliedIdentifiers(db),
             integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check"),
             foreignKeyProblems: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
             digests: try V1Snapshot.digests(db, excluding: addedInV3),
             rows: try V1Snapshot.rowCounts(db),
             withResult: try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE sender_dmarc IS NOT NULL")!,
             marked: try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE text_state = 'incomplete'")!)
        }
        let searchIndexAgrees = try db.write { db in try SearchIndexWriter.integrityCheck(db) }   // FTS5 runs its check as a write
        let plans = try db.read { db in (v2: try RetryQueries.plans(db), v3: try BackfillQueries.plans(db)) }
        #expect(after.applied == ["v1", "v2", "v3"])
        #expect(after.integrity == "ok")
        #expect(after.foreignKeyProblems == 0)
        #expect(searchIndexAgrees)
        RetryQueries.expectIndexed(plans.v2)
        BackfillQueries.expectIndexed(plans.v3)
        #expect(after.digests == before)
        #expect(after.rows == rows)
        #expect(rows["messages"] == messages && rows["messages_fts"] == messages)
        #expect(after.marked > 0)   // v2's marks were set before the upgrade, so the digests cover real values
        #expect(after.withResult == 0)
        #expect(try pending(db) == messages)
        // Mail imported after the upgrade by v3 code, and by older builds that know only v1 or v2 columns.
        try SampleRows.insert(db, atVersion: "v1")
        try SampleRows.insert(db, atVersion: "v2")
        try SampleRows.insert(db, atVersion: "v3")
        #expect(try pending(db) == messages + 2)
        try db.close()
        for (query, plan) in zip(BackfillQueries.expected, plans.v3) { print("v3 plan (upgraded copy): \(query.sql)\n    \(plan)") }
        print("v3 upgrade: \(messages) messages, \(fileSize / 1_000_000) MB database (built in \(Int(buildSeconds)) s), migrated in \(String(format: "%.3f", migrateSeconds)) s")
    }

    private let addedInV3: Set<String> = ["sender_dmarc"]

    /// As mail archived before v3: no result yet.
    private func forget(_ test: TestArchive) async throws {
        try await test.archive.database.write { db in try db.execute(sql: "UPDATE messages SET sender_dmarc = NULL") }
    }

    private func pending(_ db: some DatabaseReader) throws -> Int {
        try db.read { db in try Int.fetchOne(db, sql: BackfillQueries.count)! }
    }
}

/// The queries D-522 gives the backfill, each with the index it must use.
enum BackfillQueries {
    /// One batch, in message order from where the last one ended.
    static let batch = "SELECT id FROM messages WHERE sender_dmarc IS NULL AND id > :after ORDER BY id LIMIT :limit"
    /// How many are left, for `status` and the daemon's "anything to do?".
    static let count = "SELECT count(*) FROM messages WHERE sender_dmarc IS NULL"

    static let expected: [(sql: String, index: String)] = [
        ("SELECT id FROM messages WHERE sender_dmarc IS NULL AND id > 0 ORDER BY id LIMIT 500",
         "messages_dmarc_pending (id>?)"),
        (count, "messages_dmarc_pending"),
    ]

    static func plans(_ db: Database) throws -> [String] {
        try expected.map { query in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)").map { $0["detail"] as String }.joined(separator: "; ")
        }
    }

    static func expectIndexed(_ plans: [String]) {
        for (query, plan) in zip(expected, plans) {
            #expect(plan.contains(query.index), "\(query.sql): \(plan)")
            // Without the index the batch walks the table from :after and the count scans every row.
            let tableReads = plan.components(separatedBy: "; ").filter { !$0.contains(" INDEX ") }
            #expect(tableReads.isEmpty, "\(query.sql): \(plan)")
        }
    }
}

extension RealSizedArchive {
    /// Sets v2's columns on a share of rows, as a real v2 archive would have them:
    /// some messages marked as not read in full, attachments that failed, queue rows
    /// with import attempts.
    static func markV2(_ db: DatabasePool) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE messages SET text_state = 'incomplete', text_marked_version = 1, text_attempts = 3 WHERE id % 97 = 0")
            try db.execute(sql: "UPDATE messages SET text_attempts = 1 WHERE id % 89 = 0 AND text_state = 'complete'")
            try db.execute(sql: "UPDATE attachments SET text_failed_version = 1, text_attempts = 3, text_last_attempt_at = 1700000000 WHERE text_status IN ('unsupported', 'ocr_failed') AND id % 2 = 0")
            try db.execute(sql: "UPDATE attachments SET text_attempts = 1, text_last_attempt_at = 1700000001 WHERE text_status = 'ocr_pending' AND id % 3 = 0")
            try db.execute(sql: "UPDATE download_queue SET import_attempts = 2, last_import_attempt_at = 1700000002 WHERE uid % 7 = 0")
        }
    }
}
