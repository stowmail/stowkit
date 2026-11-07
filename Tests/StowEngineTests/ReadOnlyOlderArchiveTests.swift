import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSearch
import StowSecrets
import StowStore
import StowTestSupport
import Testing
@testable import StowEngine

/// D-605: a read-only open never migrates, so `status`, coverage, the removed
/// list and the app's reader meet an archive at `v4` (what v0.1.5 and v0.1.6
/// leave) until a newer build first writes to it. They must still report.
@Suite(.serialized) struct ReadOnlyOlderArchiveTests {
    let account = Account(id: .generate(), provider: .microsoft, email: "sam@example.com", displayName: "S")

    /// The archive as `v4` left it: no `v5`, `v6` or `v7` tables, no
    /// `folders.provider_id`. SQLite cannot drop `messages.import_batch_id`
    /// (it references `import_batches`), so `v5`'s two columns are renamed
    /// out of the way instead: any read that still names them fails, as on `v4`.
    static let backToV4 = """
        DROP TABLE gmail_queue;
        DROP TABLE gmail_sync_state;
        ALTER TABLE folders DROP COLUMN provider_id;
        DROP TABLE account_servers;
        DROP INDEX messages_imported;
        ALTER TABLE messages RENAME COLUMN import_batch_id TO not_in_v4_batch;
        ALTER TABLE messages RENAME COLUMN origin TO not_in_v4_origin;
        DROP TABLE import_failures;
        DROP TABLE import_batches;
        DELETE FROM grdb_migrations WHERE identifier IN ('v5', 'v6', 'v7');
        """

    /// Three messages in INBOX: one present, one gone at the provider, one removed from the archive.
    func makeV4Archive(at location: ArchiveLocation, keys: ArchiveKeys) async throws -> (present: StoredMessageID, gone: StoredMessageID) {
        let archive = try Archive.open(location, keys: keys)
        try archive.register(account)
        let store = ArchiveSyncStore(archive: archive)
        _ = try await store.beginFolder(account.id, folder: "INBOX", uidValidity: 1, exists: 3)
        for uid: UInt32 in 1...3 {
            let text = "From: a@example.org\r\nSubject: Quince \(uid)\r\nMessage-ID: <q\(uid)@example.org>\r\n\r\nquince \(uid)\r\n"
            try await store.write(RawMessage(key: RawMessageKey(accountID: account.id, folder: "INBOX", uidValidity: 1, uid: uid),
                                             internalDate: Date().addingTimeInterval(-Double(uid) * 86_400),
                                             size: text.utf8.count, bytes: Data(text.utf8)))
        }
        let ids = try await archive.database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }
        try await store.setSourceStates(account.id, [ids[1]: .gone], at: Date())
        _ = try ArchiveRemoval(archive: archive).remove([ids[2]], reason: "sender:example.org")
        try await archive.database.write { db in try db.execute(sql: Self.backToV4) }
        try archive.database.close()
        return (ids[0], ids[1])
    }

    @Test func statusCoverageFoldersAndTheRemovedListReadAV4Archive() async throws {
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        _ = try await makeV4Archive(at: location, keys: keys)

        let reader = try Archive.open(location, keys: keys, readOnly: true)
        // Without the fix, the first of these failed with "no such column: origin".
        let status = try #require(try ArchiveStatus.collect(reader).first)
        #expect(status.archivedMessages == 2)
        #expect(status.sourceStates[.gone] == 1)
        #expect(status.removed == 1)
        #expect(status.importedMessages == 0)
        #expect(status.unfinishedImports.isEmpty)
        let coverage = try Coverage.report(reader, account: account.id)
        #expect(coverage.queued == 0)
        let folders = try ArchiveStatus.folders(reader, account: account.id)
        #expect(folders.map(\.name) == ["INBOX"])
        let tombstones = try ArchiveRemoval(archive: reader).tombstones()
        #expect(tombstones.count == 1 && tombstones.first?.restorable == true)
        #expect(try ArchiveRemoval(archive: reader).plan(.sourceState(.gone)).messageIDs.count == 1)
        #expect(try MboxImporter.batches(reader, account: account.id).isEmpty)
        #expect(try ArchiveServers(archive: reader).server(for: account.id) == nil)
        #expect(try GmailArchiveRows.count(reader, account: account.id).isClean)

        // Nothing was written: still v4-shaped.
        let schema = try await reader.database.read { db in
            (try db.tableExists("import_batches"), try db.columns(in: "messages").map(\.name).contains("origin"),
             try ArchiveSchema.versionSummary(db))
        }
        #expect(schema.0 == false && schema.1 == false)
        #expect(schema.2.hasPrefix("Schema: v4 (upgrades the next time"))
    }

    @Test func theReaderSearchSizeAndTidyUpReadAV4Archive() async throws {
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        let ids = try await makeV4Archive(at: location, keys: keys)

        let reader = try Archive.open(location, keys: keys, readOnly: true)
        let detail = try #require(try await MessageReader(archive: reader).message(ids.present, bodyLimit: 100))
        #expect(detail.isImported == false)
        let hits = try await MessageSearcher(archive: reader).search(SearchQuery(text: "quince"))
        #expect(hits.count == 2 && hits.allSatisfy { !$0.isImported })
        let size = try MailboxSize.totals(reader, account: account.id)
        #expect(size.messages == 1)
        let tidy = try TidySummary.compute(reader, account: account.id, settings: location.root.appendingPathComponent("rules.json"))
        #expect(tidy.sourceStates.first { $0.state == .gone }?.messages == 1)
    }
}
