import Foundation
import GRDB
import StowCore
@testable import StowEngine
import StowSecrets
import StowStore
import StowTestSupport
import Testing

/// D-536: every way the engine opens an archive refuses one made by a newer
/// Stow, through `Archive.open`, before anything is changed.
@Suite(.serialized) struct NewerArchiveTests {
    let parent = TestFixtures.temporaryDirectory()
    var location: ArchiveLocation { ArchiveLocation(root: parent.appendingPathComponent("Stow", isDirectory: true)) }
    let keychain = KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
    var keyManager: KeyManager { KeyManager(keychain: keychain) }
    let gmail = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Sam")
    var refusal: ArchiveError { .newerArchive(needs: 2, knows: ArchiveSchema.readerLevel) }

    func cleanUp() {
        try? keychain.deleteAll()
        try? FileManager.default.removeItem(at: parent)
    }

    /// A confirmed archive with one account and its sign-in, marked as needing reader level 2.
    func makeNewerArchive() throws {
        let archive = try ArchiveSetup.createArchive(location, keyManager: keyManager)
        try archive.register(gmail)
        try TokenStore(keychain: keychain).save(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: nil), for: gmail.id)
        _ = try ArchiveSetup.makeRecoveryKey(archive, keyManager: keyManager)
        try ArchiveSetup.markConfirmed(archive)
        try archive.setMeta("min_reader_level", "2")
        try archive.database.close()
    }

    @Test(arguments: [false, true])
    func openingRefusesIt(readOnly: Bool) throws {
        defer { cleanUp() }
        try makeNewerArchive()
        #expect(throws: refusal) {
            _ = try ArchiveOpening.openExisting(location: location, keys: keyManager, readOnly: readOnly, environment: [:])
        }
    }

    /// Deleting needs the archive opened to remove its accounts first: refused
    /// there, before the marker, so the archive, its keys and the sign-in are all kept.
    @Test func deletionRefusesItAndDeletesNothing() throws {
        defer { cleanUp() }
        try makeNewerArchive()
        #expect(throws: refusal) { try ArchiveDeletion.delete(location, keyManager: keyManager) }
        #expect(!location.isBeingDeleted)
        #expect(FileManager.default.fileExists(atPath: location.databaseURL.path))
        #expect(try keyManager.loadKeys().databaseKeyData.count == 32)
        #expect(try TokenStore(keychain: keychain).tokens(for: gmail.id) != nil)
    }

    /// The background sync shows the message as why it cannot open the archive,
    /// and tries again later like any archive it cannot open.
    @Test func theBackgroundSyncSaysWhy() async throws {
        defer { cleanUp() }
        try makeNewerArchive()
        let location = location, keyManager = keyManager
        let scheduler = Scheduler(openArchive: { try ArchiveOpening.openExisting(location: location, keys: keyManager, readOnly: false, environment: [:]) },
                                  makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                  power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        #expect(await scheduler.round().0 == .cannotOpen("This archive was made by a newer version of Stow. Update Stow to open it."))
    }
}
