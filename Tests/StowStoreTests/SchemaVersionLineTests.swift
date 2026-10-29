import Foundation
import GRDB
import Testing
@testable import StowStore

/// `stowmail doctor` names the archive's schema version and the newest this build knows.
@Suite struct SchemaVersionLineTests {
    @Test func aCurrentArchive() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let line = try test.archive.database.read { try ArchiveSchema.versionSummary($0) }
        #expect(line == "Schema: v2. This build knows up to v2.")
    }

    @Test func aV1ArchiveOpenedReadOnly() throws {
        let keys = TestArchive.randomKeys()
        let location = ArchiveLocation(root: FileManager.default.temporaryDirectory.appendingPathComponent("stow-v1-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: location.root) }
        try location.prepare()
        let db = try EncryptedDatabase.open(at: location.databaseURL, key: keys.databaseKeyData)
        try ArchiveSchema.migrator.migrate(db, upTo: "v1")
        try db.close()
        let archive = try Archive.open(location, keys: keys, readOnly: true)
        let line = try archive.database.read { try ArchiveSchema.versionSummary($0) }
        #expect(line == "Schema: v1 (upgrades the next time this build writes to it). This build knows up to v2.")
    }

    /// An archive a newer build has written is shown as such, not as an error.
    @Test func aNewerArchive() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try test.archive.database.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v3')")
        }
        let line = try test.archive.database.read { try ArchiveSchema.versionSummary($0) }
        #expect(line == "Schema: v3, newer than this build, which knows up to v2 and reads what it knows.")
    }
}
