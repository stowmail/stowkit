import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Migration v6 (R-IMAP-1, D-577): `account_servers`, a leaf table holding an
/// `imap` account's server. It follows the mbox import's `v5` (D-562).
@Suite struct SchemaV6Tests {
    let imap = Account(id: AccountID(rawValue: "00000000-0000-4000-8000-0000000000aa"), provider: .imap,
                       email: "sam@example.net", displayName: "Sam")
    let server = AccountServer(host: "imap.example.net", port: 993, security: "tls", username: "sam.taylor", preset: "fastmail",
                               capabilities: ["IMAP4REV1", "AUTH=PLAIN"], capabilitiesAt: Date(timeIntervalSince1970: 1_762_000_000))

    @Test func v6IsTheNewestAndAddsOnlyTheLeafTable() throws {
        let test = try TestArchive()
        defer { test.remove() }
        #expect(ArchiveSchema.migrationIdentifiers.firstIndex(of: "v6") == 5) // v7 follows it (D-591)
        // As an archive at v4, with rows, then migrated: nothing else changes.
        try test.archive.database.write { db in
            try db.execute(sql: "DROP TABLE account_servers")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6'")
        }
        let (before, rows) = try test.archive.database.read { db in (try V1Snapshot.digests(db), try V1Snapshot.rowCounts(db)) }
        try ArchiveSchema.migrate(test.archive.database)
        let after = try test.archive.database.read { db in
            (applied: try ArchiveSchema.migrator.appliedIdentifiers(db), digests: try V1Snapshot.digests(db),
             rows: try V1Snapshot.rowCounts(db), level: try ArchiveSchema.readerLevelSummary(db))
        }
        #expect(after.applied == Set(ArchiveSchema.migrationIdentifiers))
        #expect(after.digests == before)
        #expect(after.rows == rows)
        #expect(after.level.hasPrefix("Reader level: needs 1"), "an older build ignores the table (D-536)")
    }

    /// The migrator answer to R-IMAP-1 (D-577): an archive made by this
    /// branch before the mbox import merged (v1 to v4, then v6, no v5; only a
    /// development probe can make one) takes the real `v5` when the merged
    /// build opens it. GRDB runs any registered migration it has not applied,
    /// in registration order, and refuses only a target older than the last
    /// applied one; nothing is erased.
    @Test func anArchiveWithV6ButNoV5TakesV5Later() throws {
        let db = try DatabaseQueue()
        var beforeMerge = DatabaseMigrator()
        beforeMerge.registerMigration("v1", migrate: ArchiveSchema.v1)
        beforeMerge.registerMigration("v2", migrate: ArchiveSchema.v2)
        beforeMerge.registerMigration("v3", migrate: ArchiveSchema.v3)
        beforeMerge.registerMigration("v4", migrate: ArchiveSchema.v4)
        beforeMerge.registerMigration("v6", migrate: ArchiveSchema.v6)
        try beforeMerge.migrate(db)
        try db.write { db in
            try db.execute(sql: "INSERT INTO accounts (id, provider, email, display_name, created_at) VALUES (?, 'imap', 'sam@example.net', 'Sam', 0)",
                           arguments: [imap.id.rawValue])
            try db.execute(sql: "INSERT INTO account_servers (account_id, host, port, security, username) VALUES (?, 'imap.example.net', 993, 'tls', 'sam.taylor')",
                           arguments: [imap.id.rawValue])
        }

        try ArchiveSchema.migrate(db)

        let (applied, tables, host) = try db.read { db in
            (try ArchiveSchema.migrator.appliedIdentifiers(db),
             try ["import_batches", "import_failures"].allSatisfy { try db.tableExists($0) },
             try String.fetchOne(db, sql: "SELECT host FROM account_servers"))
        }
        #expect(applied == Set(ArchiveSchema.migrationIdentifiers))
        #expect(tables, "v5 ran after v6")
        #expect(host == "imap.example.net", "v6's rows are untouched")
    }

    @Test func accountAndServerAreWrittenTogetherAndReadBack() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let servers = ArchiveServers(archive: test.archive)
        try servers.add(AccountRecord(account: imap), server: server)
        #expect(try servers.server(for: imap.id) == server)
        #expect(try ArchiveAccounts(archive: test.archive).record(imap.id)?.account == imap)

        // A second add with the same address fails whole: no second account, no second server.
        let twin = Account(id: .generate(), provider: .imap, email: "SAM@example.net", displayName: "Twin")
        #expect(throws: AccountDirectoryError.alreadyExists(imap.id)) { try servers.add(AccountRecord(account: twin), server: server) }
        #expect(try servers.server(for: twin.id) == nil)

        let later = Date(timeIntervalSince1970: 1_763_000_000)
        try servers.setCapabilities(["IDLE", "IMAP4REV1"], for: imap.id, at: later)
        #expect(try servers.server(for: imap.id)?.capabilities == ["IDLE", "IMAP4REV1"])
        #expect(try servers.server(for: imap.id)?.capabilitiesAt == later)
        #expect(throws: AccountDirectoryError.notFound(twin.id.rawValue)) { try servers.setCapabilities([], for: twin.id) }
    }

    /// D-570 in storage: TLS only, a real port; and the row goes with its account.
    @Test func checksHoldAndTheRowGoesWithItsAccount() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let servers = ArchiveServers(archive: test.archive)
        try servers.add(AccountRecord(account: imap), server: server)
        try test.archive.database.write { db in
            #expect(throws: DatabaseError.self) { try db.execute(sql: "UPDATE account_servers SET security = 'starttls'") }
            #expect(throws: DatabaseError.self) { try db.execute(sql: "UPDATE account_servers SET port = 0") }
            #expect(throws: DatabaseError.self) { try db.execute(sql: "UPDATE account_servers SET port = 65536") }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO account_servers (account_id, host, port, security, username) VALUES ('nobody', 'h', 993, 'tls', 'u')")
            }
        }
        // Disconnecting keeps the row (D-032); deleting the account removes it.
        try ArchiveAccounts(archive: test.archive).disconnect(imap.id)
        #expect(try servers.server(for: imap.id) != nil)
        try test.archive.database.write { db in try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [imap.id.rawValue]) }
        #expect(try servers.server(for: imap.id) == nil)
    }
}
