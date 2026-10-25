import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import StowStore
import Testing
@testable import StowEngine

/// Opening an existing archive, shared by the CLI and the app (D-411): three
/// distinct failures (D-082) and a read-only open that cannot write.
struct ArchiveOpeningTests {
    static func settings(chosen: URL?) -> ArchiveSettings {
        let defaults = UserDefaults(suiteName: "ee.getstow.stow.tests.\(UUID().uuidString)")!
        let settings = ArchiveSettings(defaults: defaults)
        settings.setChosenFolder(chosen)
        return settings
    }

    static func keychain() -> KeychainStore {
        KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
    }

    static func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stow-open-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func noArchiveWhenNothingWasChosen() throws {
        let location = ArchiveLocation(root: Self.temporary())
        #expect(throws: ArchiveOpeningError.noArchive(location.root.path)) {
            try ArchiveOpening.requireArchive(at: location, environment: [:], settings: Self.settings(chosen: nil))
        }
        // STOW_ARCHIVE_DIR wins over a chosen folder: still "no archive", not "offline".
        #expect(throws: ArchiveOpeningError.noArchive(location.root.path)) {
            try ArchiveOpening.requireArchive(at: location, environment: ["STOW_ARCHIVE_DIR": location.root.path],
                                              settings: Self.settings(chosen: location.root))
        }
    }

    @Test func offlineWhenAChosenFolderIsMissing() throws {
        let location = ArchiveLocation(root: Self.temporary())
        #expect(throws: ArchiveLocationError.offline(location.root.path)) {
            try ArchiveOpening.requireArchive(at: location, environment: [:], settings: Self.settings(chosen: location.root))
        }
    }

    @Test func keysMissingIsItsOwnError() throws {
        let root = Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ArchiveLocation(root: root)
        _ = try Archive.open(location, keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        let keychain = Self.keychain()
        #expect(throws: KeyManagerError.keysMissing(backend: .file, service: keychain.service)) {
            _ = try ArchiveOpening.openExisting(location: location, keys: KeyManager(keychain: keychain), readOnly: true,
                                                environment: [:], settings: Self.settings(chosen: nil))
        }
    }

    @Test func readOnlyOpenCannotWrite() throws {
        let root = Self.temporary()
        let keychain = Self.keychain()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? keychain.delete("key.database.v1")
            try? keychain.delete("key.files.v1")
        }
        let location = ArchiveLocation(root: root)
        let keys = try KeyManager(keychain: keychain).createKeys()
        _ = try Archive.open(location, keys: keys)
        let archive = try ArchiveOpening.openExisting(location: location, keys: KeyManager(keychain: keychain), readOnly: true,
                                                      environment: [:], settings: Self.settings(chosen: nil))
        #expect(try archive.meta("archive_id") != nil)
        #expect(throws: (any Error).self) { try archive.setMeta("written", "yes") }
    }

    @Test func keychainServiceFromTheEnvironment() {
        #expect(ArchiveOpening.keychain(["STOW_KEYCHAIN_SERVICE": "ee.getstow.stow.dev"]).service == "ee.getstow.stow.dev")
        #expect(ArchiveOpening.keychain(["STOW_KEYCHAIN_SERVICE": ""]).service == KeychainStore.defaultService)
        #expect(ArchiveOpening.keychain([:]).service == KeychainStore.defaultService)
    }
}
