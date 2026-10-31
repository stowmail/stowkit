import CryptoKit
import Foundation
import GRDB
import Testing
@testable import StowStore

/// D-536: a build refuses a file or an archive it would misread, instead of
/// returning the wrong content or skipping what it does not know.
@Suite(.serialized) struct FormatGuardTests {
    /// Seals `content` as `store` would, but with `flags` in the authenticated header.
    static func sealed(_ content: Data, hash: Data, flags: UInt8, in store: EncryptedFileStore) throws -> Data {
        let header = EncryptedFileStore.magic + [EncryptedFileStore.version, flags]
        let box = try AES.GCM.seal(content, using: store.encryptionKey, authenticating: Data(header) + hash)
        return Data(header) + box.combined!
    }

    static func place(_ file: Data, hash: Data, in store: EncryptedFileStore) throws {
        let url = store.url(for: hash)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url)
    }

    // MARK: - Flag bits

    @Test(arguments: [4, 8, 128, 4 | 1, 128 | 2] as [UInt8])
    func anUnknownFlagBitIsRefused(flags: UInt8) throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = test.archive.rawFiles
        let content = Data("Subject: a future format\r\n\r\nBody".utf8)
        let hash = store.hash(of: content)
        try Self.place(try Self.sealed(content, hash: hash, flags: flags, in: store), hash: hash, in: store)
        #expect(throws: EncryptedFileError.unsupportedFeature(flags)) { try store.read(hash) }
        #expect(throws: EncryptedFileError.unsupportedFeature(flags)) { try store.readFile(hash) }
    }

    /// A damaged file says so, whatever its flags claim: the check comes after authentication.
    @Test func anUnknownFlagBitOnADamagedFileIsAnAuthenticationFailure() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = test.archive.rawFiles
        let content = Data("Subject: x\r\n\r\ny".utf8)
        let hash = store.hash(of: content)
        var file = try Self.sealed(content, hash: hash, flags: 4, in: store)
        file[file.endIndex - 1] ^= 0xFF
        try Self.place(file, hash: hash, in: store)
        #expect(throws: EncryptedFileError.authenticationFailed) { try store.read(hash) }
    }

    @Test func everyKnownFlagCombinationStillOpens() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = test.archive.rawFiles
        let content = Data(String(repeating: "Known flags open byte for byte. ", count: 40).utf8)
        let hash = store.hash(of: content)
        let compressed = try (content as NSData).compressed(using: .lzfse) as Data
        for (flags, payload) in [(UInt8(0), content), (1, compressed), (2, content), (3, compressed)] {
            try Self.place(try Self.sealed(payload, hash: hash, flags: flags, in: store), hash: hash, in: store)
            let file = try store.readFile(hash)
            #expect(file.content == content)
            #expect(file.isSkeleton == (flags & 2 != 0))
        }
    }

    // MARK: - Reader level

    static func setLevel(_ value: String, in archive: Archive) throws {
        try archive.database.write { db in
            try db.execute(sql: "INSERT INTO archive_meta (key, value) VALUES ('min_reader_level', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                           arguments: [value])
        }
    }

    @Test(arguments: [false, true])
    func aNewerArchiveIsRefused(readOnly: Bool) throws {
        let test = try TestArchive()
        defer { test.remove() }
        try Self.setLevel("2", in: test.archive)
        try test.archive.database.close()
        #expect(throws: ArchiveError.newerArchive(needs: 2, knows: ArchiveSchema.readerLevel)) {
            _ = try Archive.open(test.location, keys: test.keys, readOnly: readOnly)
        }
    }

    /// Refused before the migrator runs or anything is written: a newer build's
    /// migration stays unknown, `archive_id` is not added, and the files keep their modes.
    @Test func aNewerArchiveIsRefusedBeforeAnythingIsWritten() throws {
        let keys = TestArchive.randomKeys()
        let location = ArchiveLocation(root: FileManager.default.temporaryDirectory.appendingPathComponent("stow-newer-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: location.root) }
        try location.prepare()
        let db = try EncryptedDatabase.open(at: location.databaseURL, key: keys.databaseKeyData)
        try ArchiveSchema.migrator.migrate(db, upTo: "v3")
        try db.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99')")
            try db.execute(sql: "INSERT INTO archive_meta (key, value) VALUES ('min_reader_level', '2')")
        }
        try db.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: location.databaseURL.path)
        let before = try Data(contentsOf: location.databaseURL)

        #expect(throws: ArchiveError.newerArchive(needs: 2, knows: ArchiveSchema.readerLevel)) {
            _ = try Archive.open(location, keys: keys)
        }

        #expect(try Data(contentsOf: location.databaseURL) == before)
        let mode = try FileManager.default.attributesOfItem(atPath: location.databaseURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o644)
        let check = try EncryptedDatabase.open(at: location.databaseURL, key: keys.databaseKeyData, readOnly: true)
        defer { try? check.close() }
        let (migrations, archiveID) = try check.read { db in
            (try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"),
             try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = 'archive_id'"))
        }
        #expect(migrations == ["v1", "v2", "v3", "v99"])
        #expect(archiveID == nil)
    }

    @Test(arguments: [nil, "1"] as [String?])
    func aMissingKeyOrLevelOneOpens(level: String?) throws {
        let test = try TestArchive()
        defer { test.remove() }
        if let level { try Self.setLevel(level, in: test.archive) }
        try test.archive.database.close()
        for readOnly in [true, false] {
            let archive = try Archive.open(test.location, keys: test.keys, readOnly: readOnly)
            try archive.database.close()
        }
    }

    /// A value this build cannot read as a level is not one it can promise to read.
    @Test func anUnreadableLevelIsRefused() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try Self.setLevel("two", in: test.archive)
        try test.archive.database.close()
        #expect(throws: ArchiveError.newerArchive(needs: nil, knows: ArchiveSchema.readerLevel)) {
            _ = try Archive.open(test.location, keys: test.keys)
        }
    }

    /// The statement a future migration uses raises the level and never lowers it.
    @Test func theLevelNeverGoesDown() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try test.archive.database.write { db in
            try ArchiveSchema.requireReaderLevel(3, db)
            try ArchiveSchema.requireReaderLevel(2, db)
        }
        #expect(try test.archive.meta("min_reader_level") == "3")
        try test.archive.database.write { db in try ArchiveSchema.requireReaderLevel(4, db) }
        #expect(try test.archive.meta("min_reader_level") == "4")
    }

    @Test func theMessageSaysToUpdateStow() {
        #expect(ArchiveError.newerArchive(needs: 2, knows: 1).description
            == "This archive was made by a newer version of Stow. Update Stow to open it.")
        #expect(EncryptedFileError.unsupportedFeature(4).description
            == "Archive file uses a feature this version of Stow does not know. Update Stow to open it.")
    }
}
