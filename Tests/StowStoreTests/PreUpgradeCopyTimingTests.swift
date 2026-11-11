import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowStore

/// D-606, D-607: what the copy before a migration adds to an update on an
/// archive the size of a real one. Built at v1, migrated to this build's newest
/// version, then given a test-only `v8` that changes nothing, so the time is
/// the copy, its check and the bookkeeping.
///
/// 2,000 messages by default, so every `check.sh` and CI run covers it. For the
/// full size (D-607 records the measured run), in a release build:
///
///     STOW_MIGRATION_MESSAGES=40000 swift test -c release -Xswiftc -enable-testing --filter PreUpgradeCopyTimingTests
@Suite struct PreUpgradeCopyTimingTests {
    @Test func theCopyOnARealSizedArchive() throws {
        let messages = Int(ProcessInfo.processInfo.environment["STOW_MIGRATION_MESSAGES"] ?? "") ?? 2_000
        let keys = TestArchive.randomKeys()
        let location = ArchiveLocation(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("stow-copy-\(UUID().uuidString)", isDirectory: true))
        try location.prepare()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let database = try EncryptedDatabase.open(at: location.databaseURL, key: keys.databaseKeyData)
        try ArchiveSchema.migrator.migrate(database, upTo: "v1")
        try RealSizedArchive.fill(database, messages: messages)
        try ArchiveSchema.migrate(database)
        let size = PreUpgradeCopy.fileSize(location.databaseURL) + PreUpgradeCopy.fileSize(PreUpgradeCopy.walURL(location.databaseURL))

        let upgrade = ArchiveUpgrade(adding: [.init(identifier: "v8") { _ in }], availableBytes: { _ in nil })
        let started = Date()
        try PreUpgradeCopy.migrate(database, location: location, keys: keys, upgrade: upgrade, diskSync: .system)
        let seconds = Date().timeIntervalSince(started)

        let copy = location.root.appendingPathComponent("pre-upgrade-v7-to-v8.db")
        let checkStarted = Date()
        #expect(PreUpgradeCopy.check(copy, key: KeyBuffer(keys.databaseKey), applied: Set(ArchiveSchema.migrationIdentifiers)))
        let checkSeconds = Date().timeIntervalSince(checkStarted)
        // For comparison only: SQLite's lighter check, which skips matching each index against its table.
        let quickStarted = Date()
        let quick = try DatabaseQueue(path: copy.path, configuration: PreUpgradeCopy.keyed(KeyBuffer(keys.databaseKey), readOnly: true))
        #expect(try quick.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") } == ["ok"])
        try quick.close()
        let quickSeconds = Date().timeIntervalSince(quickStarted)
        #expect(try database.read { db in try ArchiveSchema.migrator.appliedIdentifiers(db) }.contains("v8"))
        try database.close()
        print("pre-upgrade copy: \(messages) messages, \(size / 1_000_000) MB database; copy, check and migrate in \(String(format: "%.3f", seconds)) s (integrity_check alone \(String(format: "%.3f", checkSeconds)) s, quick_check \(String(format: "%.3f", quickSeconds)) s)")
    }
}
