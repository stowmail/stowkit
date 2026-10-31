import CryptoKit
import Foundation
import StowCore
@testable import StowEngine
import StowSecrets
import StowStore
import StowTestSupport
import Testing

/// R17 (UI-16, D-530): deleting the archive takes the writer lock, deletes the
/// folder's files and its two keys and nothing else, and a deletion stopped at
/// any step leaves a working archive or one every open refuses.
@Suite(.serialized) struct ArchiveDeletionTests {
    let parent = TestFixtures.temporaryDirectory()
    var location: ArchiveLocation { ArchiveLocation(root: parent.appendingPathComponent("Stow", isDirectory: true)) }
    let keychain = KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
    var keyManager: KeyManager { KeyManager(keychain: keychain) }
    let gmail = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Sam")
    let icloud = Account(id: .generate(), provider: .icloud, email: "sam@icloud.com", displayName: "Sam")

    func cleanUp() {
        try? keychain.deleteAll()
        try? FileManager.default.removeItem(at: parent)
    }

    /// An archive made as the app makes it, with two accounts and their sign-ins,
    /// a confirmed recovery key, a waiting one, a rules file and a sibling file outside it.
    func makeArchive() throws {
        let archive = try ArchiveSetup.createArchive(location, keyManager: keyManager)
        try archive.register(gmail)
        try archive.register(icloud)
        try TokenStore(keychain: keychain).save(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: nil), for: gmail.id)
        try PasswordStore(keychain: keychain).save(try AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop"), for: icloud.id)
        _ = try ArchiveSetup.makeRecoveryKey(archive, keyManager: keyManager)
        try ArchiveSetup.markConfirmed(archive)
        _ = try ArchiveSetup.makeRecoveryKey(archive, keyManager: keyManager)
        try Data("{}".utf8).write(to: location.root.appendingPathComponent("rules.json"))
        try archive.database.close()
        try Data("keep".utf8).write(to: parent.appendingPathComponent("beside.txt"))
    }

    @Test func deletesTheArchiveItsKeysAndSignInsAndNothingElse() throws {
        defer { cleanUp() }
        try makeArchive()
        let other = KeychainStore(service: keychain.service + ".other", backend: .file, fileVaultIsOn: { true })
        defer { try? other.deleteAll() }
        try other.set(Data("x".utf8), for: "key.database.v1")

        let outcome = try ArchiveDeletion.delete(location, keyManager: keyManager)

        #expect(Set(outcome.removedAccounts.map(\.id)) == [gmail.id, icloud.id])
        #expect(outcome.deletedKeys && outcome.removedFolder)
        #expect(!FileManager.default.fileExists(atPath: location.root.path))
        #expect(try keychain.items().isEmpty)
        #expect(try other.get("key.database.v1") != nil)
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("beside.txt").path))
    }

    @Test func leavesFilesItDidNotMakeAndTheFolderWithThem() throws {
        defer { cleanUp() }
        try makeArchive()
        try Data("mine".utf8).write(to: location.root.appendingPathComponent("notes.txt"))
        let outcome = try ArchiveDeletion.delete(location, keyManager: keyManager)
        #expect(!outcome.removedFolder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: location.root.path) == ["notes.txt"])
    }

    @Test func refusesWhileAnotherWriterHoldsTheLock() throws {
        defer { cleanUp() }
        try makeArchive()
        let lock = try ArchiveLock.acquire(location)
        defer { lock.release() }
        #expect(throws: ArchiveDeletionError.busy) { try ArchiveDeletion.delete(location, keyManager: keyManager) }
        #expect(location.exists && !location.isBeingDeleted)
        #expect(try keyManager.keysExist())
    }

    @Test func refusesAMovedFolder() throws {
        defer { cleanUp() }
        try makeArchive()
        try location.writeMovedMarker(to: parent.appendingPathComponent("elsewhere"))
        #expect(throws: ArchiveLocationError.moved(parent.appendingPathComponent("elsewhere").path)) {
            try ArchiveDeletion.delete(location, keyManager: keyManager)
        }
        #expect(location.exists)
        #expect(try keyManager.keysExist())
    }

    @Test func refusesAFolderWithNoArchive() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
        #expect(throws: ArchiveDeletionError.notAnArchive(location.root.path)) {
            try ArchiveDeletion.delete(location, keyManager: keyManager)
        }
        #expect(!FileManager.default.fileExists(atPath: location.lockURL.path))
    }

    /// Keys that belong to another archive are never deleted, and nothing is.
    @Test func refusesKeysThatDoNotOpenThisArchive() throws {
        defer { cleanUp() }
        try makeArchive()
        let stranger = ArchiveLocation(root: parent.appendingPathComponent("Other", isDirectory: true))
        let strangerKeys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        try Archive.open(stranger, keys: strangerKeys).database.close()
        #expect(throws: ArchiveDeletionError.keysNotThisArchives(stranger.root.path)) {
            try ArchiveDeletion.delete(stranger, keyManager: keyManager)
        }
        #expect(stranger.exists && !stranger.isBeingDeleted)
        #expect(try keyManager.keysExist())
    }

    @Test func refusesWithNoKeys() throws {
        defer { cleanUp() }
        try makeArchive()
        try keyManager.deleteKeys()
        #expect(throws: ArchiveDeletionError.noKeys(location.root.path)) { try ArchiveDeletion.delete(location, keyManager: keyManager) }
        #expect(location.exists)
    }

    struct Stop: Error {}

    /// Stopped before each step: up to the marker the archive still opens; from
    /// it on, every open, create and folder check refuses it, and running the
    /// deletion again finishes it.
    @Test(arguments: ArchiveDeletion.Step.allCases)
    func aDeletionStoppedAtAnyStepIsSafeAndCanFinish(_ stop: ArchiveDeletion.Step) throws {
        defer { cleanUp() }
        try makeArchive()
        #expect(throws: Stop.self) {
            try ArchiveDeletion.delete(location, keyManager: keyManager) { if $0 == stop { throw Stop() } }
        }
        if stop == .accounts || stop == .marker {
            let archive = try ArchiveOpening.openExisting(location: location, keys: keyManager, readOnly: true, environment: [:])
            #expect(try ArchiveAccounts(archive: archive).all().count == 2)
            try archive.database.close()
            #expect(ArchiveLocation.checkFolder(location.root).contents == .archive)
        } else {
            let refused = ArchiveLocationError.beingDeleted(location.root.path)
            #expect(throws: refused) { try ArchiveOpening.requireArchive(at: location, environment: [:]) }
            #expect(throws: refused) { try ArchiveSetup.createArchive(location, keyManager: keyManager) }
            #expect(ArchiveLocation.checkFolder(location.root).contents == .beingDeleted)
            if let keys = try? keyManager.loadKeys() {
                #expect(throws: refused) { try Archive.open(location, keys: keys, readOnly: true) }
            }
        }
        _ = try ArchiveDeletion.delete(location, keyManager: keyManager)
        #expect(!FileManager.default.fileExists(atPath: location.root.path))
        #expect(try !keyManager.keysExist())
        #expect(try keychain.items().isEmpty)
    }

    /// With the database gone, an unfinished deletion deletes only the keys it
    /// started with, never a pair made for another archive meanwhile.
    @Test func carryingOnLeavesKeysItDidNotStartWith() throws {
        defer { cleanUp() }
        try makeArchive()
        #expect(throws: Stop.self) {
            try ArchiveDeletion.delete(location, keyManager: keyManager) { if $0 == .keys { throw Stop() } }
        }
        try keyManager.deleteKeys()
        try keyManager.createKeys()
        let outcome = try ArchiveDeletion.delete(location, keyManager: keyManager)
        #expect(!outcome.deletedKeys)
        #expect(try keyManager.keysExist())
        #expect(!FileManager.default.fileExists(atPath: location.root.path))
    }

    @Test func theMarkerNamesAKeyDigestAndNoKey() throws {
        defer { cleanUp() }
        try makeArchive()
        let keys = try keyManager.loadKeys()
        #expect(throws: Stop.self) {
            try ArchiveDeletion.delete(location, keyManager: keyManager) { if $0 == .database { throw Stop() } }
        }
        let text = try String(contentsOf: location.deletingMarkerURL, encoding: .utf8)
        #expect(text.contains(keys.digest.hex))
        #expect(!text.contains(keys.databaseKeyData.map { String(format: "%02x", $0) }.joined()))
        #expect(KeysDigest(hex: keys.digest.hex)?.matches(keys.digest) == true)
        #expect(KeysDigest(hex: "zz") == nil)
    }
}

/// R16 (D-529): what the location step learns about a folder, without changing it.
@Suite struct FolderCheckTests {
    let parent = TestFixtures.temporaryDirectory()

    @Test func anEmptyOrNewFolderOnTheStartupDiskIsSuitable() throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fresh = parent.appendingPathComponent("New", isDirectory: true)
        for url in [parent, fresh] {
            let check = ArchiveLocation.checkFolder(url)
            #expect(check.volume.verdict == .suitable)
            #expect(check.contents == .empty)
            #expect((check.availableBytes ?? 0) > 0)
            #expect(check.volumeName?.isEmpty == false)
        }
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func saysWhatIsInTheFolder() throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        let archive = ArchiveLocation(root: parent.appendingPathComponent("Archive"))
        try Archive.open(archive, keys: keys).database.close()
        #expect(ArchiveLocation.checkFolder(archive.root).contents == .archive)

        let other = parent.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: other.appendingPathComponent(".DS_Store"))
        #expect(ArchiveLocation.checkFolder(other).contents == .empty)
        try Data().write(to: other.appendingPathComponent("photo.jpg"))
        #expect(ArchiveLocation.checkFolder(other).contents == .otherFiles)

        try archive.writeMovedMarker(to: other)
        #expect(ArchiveLocation.checkFolder(archive.root).contents == .moved(other.standardizedFileURL.path))
    }

    @Test func refusesACloudFolderWithTheReason() {
        let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/Stow")
        guard case .refused(let reason) = ArchiveLocation.checkFolder(iCloudDrive).volume.verdict else {
            Issue.record("not refused")
            return
        }
        #expect(reason.contains("cloud"))
    }
}
