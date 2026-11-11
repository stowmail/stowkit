import CryptoKit
import Foundation
import GRDB
import os
import StowCore
@testable import StowEngine
import StowSecrets
@testable import StowStore
import StowTestSupport
import Testing

/// A throwaway archive for the D-606 tests, with test-only migrations that are never shipped.
struct UpgradeFixture {
    struct Failure: Error {}

    let parent = TestFixtures.temporaryDirectory()
    var location: ArchiveLocation { ArchiveLocation(root: parent.appendingPathComponent("Stow", isDirectory: true)) }
    let keychain = KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
    var keyManager: KeyManager { KeyManager(keychain: keychain) }
    let account = Account(id: .generate(), provider: .microsoft, email: "sam@example.com", displayName: "Sam")
    static let day: TimeInterval = 86_400
    /// This build's migrations, which every test archive starts at.
    static let current = Set(ArchiveSchema.migrationIdentifiers)

    func cleanUp() {
        try? keychain.deleteAll()
        try? FileManager.default.removeItem(at: parent)
    }

    var keys: ArchiveKeys { get throws { try keyManager.loadKeys() } }

    /// An archive at this build's newest version, with its keys in the test
    /// Keychain, an account and one stored message; closed afterwards.
    @discardableResult
    func makeArchive() throws -> StoredMessageID {
        let archive = try ArchiveSetup.createArchive(location, keyManager: keyManager)
        try archive.register(account)
        let bytes = Data("From: a@example.org\r\nTo: sam@example.com\r\nSubject: Kittiwake\r\n\r\nHello.\r\n".utf8)
        let outcome = try Importer(archive: archive).importMessage(
            RawMessage(key: RawMessageKey(accountID: account.id, folder: "INBOX", uidValidity: 1, uid: 1),
                       internalDate: Date(timeIntervalSince1970: 1_756_720_800), size: bytes.count, bytes: bytes))
        try archive.database.close()
        guard case .imported(let id) = outcome else { throw Failure() }
        return id
    }

    /// A test migration: a new table, and one changed value so the copy can be told from the result.
    static func migration(_ name: String, sleep: TimeInterval = 0, fail: Bool = false) -> ArchiveUpgrade.Migration {
        ArchiveUpgrade.Migration(identifier: name) { db in
            if sleep > 0 { Thread.sleep(forTimeInterval: sleep) }
            try db.execute(sql: "CREATE TABLE test_\(name) (x INTEGER)")
            try db.execute(sql: "UPDATE accounts SET display_name = 'changed by \(name)'")
            if fail { throw Failure() }
        }
    }

    /// Opens for writing with `upgrade` and closes again.
    func open(_ upgrade: ArchiveUpgrade) throws {
        let archive = try Archive.open(location, keys: try keys, upgrade: upgrade)
        try archive.database.close()
    }

    /// The pre-upgrade copies in the folder, by name.
    func copies() -> [String] {
        names().filter { $0.hasPrefix("pre-upgrade-") && $0.hasSuffix(".db") }.sorted()
    }

    func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: location.root.path)) ?? []
    }

    func url(_ name: String) -> URL { location.root.appendingPathComponent(name) }

    /// Reads `url` with the archive's key, read-only.
    func read<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        let database = try EncryptedDatabase.open(at: url, key: KeyBuffer(try keys.databaseKey), readOnly: true)
        defer { try? database.close() }
        return try database.read(body)
    }

    func applied(_ url: URL) throws -> Set<String> {
        try read(url) { db in try ArchiveSchema.migrator.appliedIdentifiers(db) }
    }

    func meta(_ key: String, in url: URL? = nil) throws -> String? {
        try read(url ?? location.databaseURL) { db in
            try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = ?", arguments: [key])
        }
    }

    /// A digest of every row of every ordinary table, so a copy can be shown identical to the original.
    func digest(_ url: URL, leavingOut: Set<String> = []) throws -> [String: Data] {
        try read(url) { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name
                """)
            var result: [String: Data] = [:]
            for table in tables where !leavingOut.contains(table) {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").map(\.description).sorted()
                result[table] = Data(SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)))
            }
            return result
        }
    }
}

/// D-606: before a format migration the engine copies the database, checks the
/// copy, and only then migrates; the copy goes after 7 days, at the next
/// migration, or with the archive.
@Suite(.serialized) struct PreUpgradeCopyTests {
    let fixture = UpgradeFixture()
    var v8: ArchiveUpgrade { ArchiveUpgrade(adding: [UpgradeFixture.migration("v8")]) }

    @Test func aMigrationMakesACopyFirst() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        let before = try fixture.digest(fixture.location.databaseURL)
        try fixture.open(v8)

        #expect(fixture.copies() == ["pre-upgrade-v7-to-v8.db"])
        let copy = fixture.url("pre-upgrade-v7-to-v8.db")
        // Opens with the archive's key, is at v7, and holds every row as it was.
        #expect(try fixture.applied(copy) == UpgradeFixture.current)
        #expect(try fixture.digest(copy) == before)
        #expect(try fixture.applied(fixture.location.databaseURL) == UpgradeFixture.current.union(["v8"]))
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try fixture.meta("pre_upgrade_copy") == "pre-upgrade-v7-to-v8.db")
        #expect(try fixture.meta("pre_upgrade_migrated_at") != nil)
        // Nothing half-made is left beside it.
        #expect(!fixture.names().contains { $0.hasPrefix(".tmp-pre-upgrade") || $0.hasPrefix("pre-upgrade-v7-to-v8.db-") })
    }

    /// Once migrated, opening again with the same migrations copies nothing.
    @Test func noCopyWhenUpToDate() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        try fixture.open(v8)
        #expect(fixture.copies() == ["pre-upgrade-v7-to-v8.db"])
        let checks = OSAllocatedUnfairLock(initialState: 0)
        try fixture.open(ArchiveUpgrade(adding: [UpgradeFixture.migration("v8")], willCheckCopy: { _ in checks.withLock { $0 += 1 } }))
        #expect(checks.withLock { $0 } == 0)
        #expect(fixture.copies() == ["pre-upgrade-v7-to-v8.db"])
    }

    /// A brand-new archive has nothing to keep: it migrates straight to the newest version.
    @Test func noCopyForANewArchive() throws {
        defer { fixture.cleanUp() }
        let archive = try Archive.open(fixture.location, keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256),
                                                                             fileKey: SymmetricKey(size: .bits256)), upgrade: v8)
        let applied = try archive.database.read { db in try ArchiveSchema.migrator.appliedIdentifiers(db) }
        try archive.database.close()
        #expect(applied.contains("v8"))
        #expect(fixture.copies().isEmpty)
    }

    @Test func aFailedMigrationLeavesTheOriginalAndTheCopy() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        let before = try fixture.digest(fixture.location.databaseURL)
        #expect(throws: UpgradeFixture.Failure.self) {
            try fixture.open(ArchiveUpgrade(adding: [UpgradeFixture.migration("v8", fail: true)]))
        }
        #expect(try fixture.applied(fixture.location.databaseURL) == UpgradeFixture.current)
        #expect(try fixture.digest(fixture.location.databaseURL) == before)
        #expect(fixture.copies() == ["pre-upgrade-v7-to-v8.db"])
        #expect(try fixture.digest(fixture.url("pre-upgrade-v7-to-v8.db")) == before)
    }

    /// A copy that fails its check is deleted and the open refused, with the archive unchanged.
    @Test func theCopyIsCheckedBeforeMigrating() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        let before = try fixture.digest(fixture.location.databaseURL)
        let damage: @Sendable (URL) throws -> Void = { url in
            // Overwrite a page in the middle of the copy, as a bad sector would.
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: 8192)
            try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
            try handle.close()
        }
        #expect(throws: ArchiveError.upgradeCopyFailedCheck) {
            try fixture.open(ArchiveUpgrade(adding: [UpgradeFixture.migration("v8")], willCheckCopy: damage))
        }
        #expect(fixture.copies().isEmpty)
        #expect(!fixture.names().contains { $0.hasPrefix(".tmp-pre-upgrade") })
        #expect(try fixture.applied(fixture.location.databaseURL) == UpgradeFixture.current)
        #expect(try fixture.digest(fixture.location.databaseURL) == before)
    }

    @Test func expiresAfterSevenDays() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        let migrated = Date()
        try fixture.open(ArchiveUpgrade(adding: [UpgradeFixture.migration("v8")], now: { migrated }))
        #expect(fixture.copies().count == 1)

        try fixture.open(ArchiveUpgrade(adding: [UpgradeFixture.migration("v8")], now: { migrated + 6 * UpgradeFixture.day }))
        #expect(fixture.copies() == ["pre-upgrade-v7-to-v8.db"])
        #expect(try fixture.meta("pre_upgrade_copy") != nil)

        try fixture.open(ArchiveUpgrade(adding: [UpgradeFixture.migration("v8")], now: { migrated + 8 * UpgradeFixture.day }))
        #expect(fixture.copies().isEmpty)
        #expect(!fixture.names().contains { $0.hasPrefix("pre-upgrade-") })
        #expect(try fixture.meta("pre_upgrade_copy") == nil)
        #expect(try fixture.meta("pre_upgrade_migrated_at") == nil)
    }

    /// One copy at a time: the next migration's copy replaces it, and the old
    /// one is deleted only after the new one passes its check.
    @Test func theNextMigrationReplacesIt() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        try fixture.open(v8)
        let afterV8 = try fixture.digest(fixture.location.databaseURL)
        let old = fixture.url("pre-upgrade-v7-to-v8.db")

        // The v9 copy fails its check: the v8 copy is still there, and still recorded.
        let fail: @Sendable (URL) throws -> Void = { url in
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: 8192)
            try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
            try handle.close()
        }
        let both = [UpgradeFixture.migration("v8"), UpgradeFixture.migration("v9")]
        #expect(throws: ArchiveError.upgradeCopyFailedCheck) { try fixture.open(ArchiveUpgrade(adding: both, willCheckCopy: fail)) }
        #expect(fixture.copies() == ["pre-upgrade-v7-to-v8.db"])
        #expect(try fixture.meta("pre_upgrade_copy") == "pre-upgrade-v7-to-v8.db")

        let oldThereAtCheck = OSAllocatedUnfairLock(initialState: false)
        try fixture.open(ArchiveUpgrade(adding: both, willCheckCopy: { _ in
            oldThereAtCheck.withLock { $0 = FileManager.default.fileExists(atPath: old.path) }
        }))
        #expect(oldThereAtCheck.withLock { $0 })
        #expect(fixture.copies() == ["pre-upgrade-v8-to-v9.db"])
        #expect(try fixture.digest(fixture.url("pre-upgrade-v8-to-v9.db")) == afterV8)
        #expect(try fixture.meta("pre_upgrade_copy") == "pre-upgrade-v8-to-v9.db")
    }

    @Test func refusesWithoutSpace() async throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        let database = fixture.location.databaseURL
        let bytesBefore = try Data(contentsOf: database)
        let size = Int64(bytesBefore.count)
        let short = ArchiveUpgrade(adding: [UpgradeFixture.migration("v8")], availableBytes: { _ in size })
        do {
            try fixture.open(short)
            Issue.record("opened without room for the copy")
        } catch ArchiveError.notEnoughSpaceToUpgrade(let needed) {
            #expect(needed > size)
        }
        #expect(ArchiveError.notEnoughSpaceToUpgrade(needed: 734_003_200).description
            == "Stow needs about 734 MB free to update your archive safely. Free up some space and open Stow again.")
        // Nothing written: no copy, no temporary file, the database's bytes and migrations as they were.
        #expect(!fixture.names().contains { $0.hasPrefix("pre-upgrade-") || $0.hasPrefix(".tmp-pre-upgrade") })
        #expect(try Data(contentsOf: database) == bytesBefore)
        #expect(try fixture.applied(database) == UpgradeFixture.current)

        // The background sync says why, and waits for the next round (60 s) like a newer archive.
        let location = fixture.location, keys = try fixture.keys
        let scheduler = Scheduler(openArchive: { try Archive.open(location, keys: keys, upgrade: short) },
                                  makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                  power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        guard case .cannotOpen(let reason) = await scheduler.round().0 else {
            Issue.record("the round did not stop at the open")
            return
        }
        #expect(reason.hasPrefix("Stow needs about "))
        #expect(try fixture.applied(database) == UpgradeFixture.current)
    }

    /// Two openers at once (the background sync and a command right after an
    /// update): one copies and migrates, the other waits and finds nothing to do.
    @Test func onlyOneProcessCopies() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let failures = OSAllocatedUnfairLock(initialState: [String]())
        let upgrade = ArchiveUpgrade(adding: [UpgradeFixture.migration("v8", sleep: 0.5)],
                                     willCheckCopy: { _ in checks.withLock { $0 += 1 } })
        let location = fixture.location, keys = try fixture.keys
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                let archive = try Archive.open(location, keys: keys, upgrade: upgrade)
                try archive.database.close()
            } catch {
                failures.withLock { $0.append(String(describing: error)) }
            }
        }
        #expect(failures.withLock { $0 } == [])
        #expect(checks.withLock { $0 } == 1)
        #expect(fixture.copies() == ["pre-upgrade-v7-to-v8.db"])
        #expect(try fixture.applied(fixture.location.databaseURL) == UpgradeFixture.current.union(["v8"]))
    }

    @Test func deletionRemovesTheCopy() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        try fixture.open(v8)
        #expect(fixture.copies().count == 1)
        let outcome = try ArchiveDeletion.delete(fixture.location, keyManager: fixture.keyManager)
        #expect(outcome.removedFolder)
        #expect(!FileManager.default.fileExists(atPath: fixture.location.root.path))
    }

    @Test func relocationTakesTheCopy() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        try fixture.open(v8)
        let keys = try fixture.keys
        let archive = try Archive.open(fixture.location, keys: keys)
        try RecoveryBundle.write(keys, archiveID: try archive.archiveID(), recoveryKey: .generate(), to: fixture.location.root)
        let destination = fixture.parent.appendingPathComponent("moved", isDirectory: true)
        let settings = ArchiveSettings(defaults: UserDefaults(suiteName: "ee.getstow.tests.\(UUID().uuidString)")!)
        let outcome = try ArchiveRelocation.move(archive, to: destination, keys: keys, environment: [:], agentEnvironment: [:],
                                                 settings: settings, say: { _ in }, confirmDelete: { _ in true })
        #expect(outcome == .moved(deletedOld: true))
        let moved = ArchiveLocation(root: destination)
        let copy = moved.root.appendingPathComponent("pre-upgrade-v7-to-v8.db")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try fixture.applied(copy) == UpgradeFixture.current)
        // Nothing of it is left in the old folder.
        #expect(!fixture.names().contains { $0.hasPrefix("pre-upgrade-") })
        // The moved archive still names it, so it expires there as it would have here.
        let reopened = try Archive.open(moved, keys: keys)
        #expect(try reopened.meta("pre_upgrade_copy") == "pre-upgrade-v7-to-v8.db")
        try reopened.database.close()
    }
}
