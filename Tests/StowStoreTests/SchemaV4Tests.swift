import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Migration v4 (D-523): the DMARC rule loosened (a pass for a parent of the From
/// domain counts), so every stored result is cleared once and the backfill reads
/// it again by the new rule (D-522). The test account is Microsoft.
@Suite(.serialized) struct SchemaV4Tests {
    static let parentPass = "mx.microsoft.com 1; spf=pass (sender IP is 192.0.2.1) smtp.mailfrom=paypal.com; dkim=pass (signature was verified) header.d=paypal.com;dmarc=pass action=none header.from=paypal.com;compauth=pass reason=100"

    /// From a subdomain, with the provider's pass naming its parent: `fail` by v0.1.4's rule, `pass` by D-523's.
    static func subdomainMessage() -> Data {
        Data("""
            Authentication-Results: \(parentPass)\r
            From: PayPal <service@mail.paypal.com>\r
            To: sam@example.com\r
            Subject: Receipt\r
            Message-ID: <sub@example.org>\r
            \r
            Thank you.\r

            """.utf8)
    }

    @Test func v4IsTheNewest() {
        #expect(ArchiveSchema.migrationIdentifiers.last == "v4")
    }

    @Test func v4ClearsEveryStoredResultAndTheBackfillReadsThemAgain() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = SenderDMARCStoreTests()
        let ids = try store.importMessages(test, count: 6)
        guard case .imported(let sub) = try Importer(archive: test.archive).importMessage(test.raw(Self.subdomainMessage(), uid: 100)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // As v0.1.4 stored it, then as an archive at v3.
        try test.archive.database.write { db in
            try db.execute(sql: "UPDATE messages SET sender_dmarc = 'fail' WHERE id = ?", arguments: [sub])
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4'")
        }
        let (before, rows) = try test.archive.database.read { db in
            (try V1Snapshot.digests(db, excluding: ["sender_dmarc"]), try V1Snapshot.rowCounts(db))
        }

        try ArchiveSchema.migrate(test.archive.database)

        let after = try test.archive.database.read { db in
            (applied: try ArchiveSchema.migrator.appliedIdentifiers(db),
             digests: try V1Snapshot.digests(db, excluding: ["sender_dmarc"]),
             rows: try V1Snapshot.rowCounts(db))
        }
        #expect(after.applied == Set(ArchiveSchema.migrationIdentifiers))
        #expect(after.digests == before)
        #expect(after.rows == rows)
        #expect(try test.count("messages", "sender_dmarc IS NOT NULL") == 0)
        let backfill = SenderDMARCBackfill(archive: test.archive)
        #expect(try backfill.pending() == 7)

        #expect(try backfill.run() == SenderDMARCBackfillSummary(read: 7, unreadable: 0, stopped: false))
        let values = try store.stored(test)
        for (n, id) in ids.enumerated() { #expect(values[id] == SenderDMARCStoreTests.expected(n).rawValue, "message \(n)") }
        #expect(values[sub] == "pass")

        // A migration runs once: reopening keeps what the backfill wrote.
        let again = try Archive.open(test.location, keys: test.keys)
        #expect(try again.database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE sender_dmarc IS NULL") } == 0)
    }
}
