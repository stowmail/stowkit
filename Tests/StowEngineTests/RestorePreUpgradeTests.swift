import Foundation
import GRDB
import StowCore
@testable import StowEngine
import StowSecrets
@testable import StowStore
import StowTestSupport
import Testing

/// D-606 item 5: `stowmail restore-pre-upgrade` puts the copy back, keeps the
/// replaced database aside for 7 days, and says what is missing since.
@Suite(.serialized) struct RestorePreUpgradeTests {
    let fixture = UpgradeFixture()
    var v8: ArchiveUpgrade { ArchiveUpgrade(adding: [UpgradeFixture.migration("v8")]) }

    @Test func aRoundTripBackToTheOlderFormat() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        let before = try fixture.digest(fixture.location.databaseURL, leavingOut: ["archive_meta"])
        try fixture.open(v8)
        let plan = try PreUpgradeRestore.plan(fixture.location, keys: try fixture.keys)
        #expect(plan.copyName == "pre-upgrade-v7-to-v8.db" && plan.from == "v7" && plan.to == "v8")

        let restoredAt = Date()
        let outcome = try PreUpgradeRestore.restore(fixture.location, keys: try fixture.keys, now: restoredAt)
        let database = fixture.location.databaseURL
        #expect(try fixture.applied(database) == UpgradeFixture.current)
        #expect(try fixture.digest(database, leavingOut: ["archive_meta"]) == before)
        #expect(outcome.report.isClean && outcome.missingFiles.isEmpty)
        // The copy is the archive now; its keys are cleared and the replaced database is recorded.
        #expect(fixture.copies().isEmpty)
        #expect(try fixture.meta("pre_upgrade_copy") == nil)
        #expect(try fixture.meta("replaced_by_restore") == outcome.replacedName)
        #expect(outcome.replacedName.hasPrefix("replaced-by-restore-") && outcome.replacedName.hasSuffix(".db"))
        let replaced = fixture.url(outcome.replacedName)
        #expect(try fixture.applied(replaced) == UpgradeFixture.current.union(["v8"]))
        let mode = try FileManager.default.attributesOfItem(atPath: replaced.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        // The replaced database goes by the same 7-day rule.
        try fixture.open(ArchiveUpgrade(now: { restoredAt + 6 * UpgradeFixture.day }))
        #expect(FileManager.default.fileExists(atPath: replaced.path))
        try fixture.open(ArchiveUpgrade(now: { restoredAt + 8 * UpgradeFixture.day }))
        #expect(!fixture.names().contains { $0.hasPrefix("replaced-by-restore-") })
        #expect(try fixture.meta("replaced_by_restore") == nil)
    }

    @Test func refusesWhileTheWriterLockIsHeld() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        try fixture.open(v8)
        let lock = try ArchiveLock.acquire(fixture.location)
        defer { lock.release() }
        #expect(throws: PreUpgradeRestoreError.busy) {
            _ = try PreUpgradeRestore.restore(fixture.location, keys: try fixture.keys)
        }
        #expect(try fixture.applied(fixture.location.databaseURL) == UpgradeFixture.current.union(["v8"]))
        #expect(fixture.copies() == ["pre-upgrade-v7-to-v8.db"])
    }

    /// Tidy-up removed a message's file after the copy was made: the copy still
    /// lists the message, and the restore says its file is gone.
    @Test func reportsAMessageWhoseFileWasRemovedSince() throws {
        defer { fixture.cleanUp() }
        let id = try fixture.makeArchive()
        try fixture.open(v8)
        let keys = try fixture.keys
        let archive = try Archive.open(fixture.location, keys: keys)
        let hash = try archive.database.read { db in
            try Data.fetchOne(db, sql: "SELECT raw_hash FROM messages WHERE id = ?", arguments: [id])!
        }
        _ = try ArchiveRemoval(archive: archive).remove([id], reason: "test")
        #expect(!archive.rawFiles.exists(hash))
        try archive.database.close()

        let outcome = try PreUpgradeRestore.restore(fixture.location, keys: keys)
        #expect(outcome.missingFiles == [id])
        #expect(!outcome.report.isClean)
    }

    @Test func nothingToRestoreWithoutACopy() throws {
        defer { fixture.cleanUp() }
        try fixture.makeArchive()
        #expect(throws: PreUpgradeRestoreError.noCopy) { _ = try PreUpgradeRestore.plan(fixture.location, keys: try fixture.keys) }
        #expect(throws: PreUpgradeRestoreError.noCopy) { _ = try PreUpgradeRestore.restore(fixture.location, keys: try fixture.keys) }
    }
}
