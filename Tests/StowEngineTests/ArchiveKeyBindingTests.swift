import CryptoKit
import Foundation
import StowCore
@testable import StowEngine
import StowSecrets
import StowStore
import StowTestSupport
import Testing

/// A-09: archive keys are added, never overwritten, and a recovery bundle only
/// ever wraps the keys the archive was opened with.
@Suite(.serialized) struct ArchiveKeyBindingTests {
    let keychain = testKeychain()
    let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())

    func cleanUp() {
        try? keychain.deleteAll()
        try? FileManager.default.removeItem(at: location.root)
    }

    static func otherKeys() -> ArchiveKeys {
        ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
    }

    /// Two `init` runs at once (or the app and the CLI) on the same Keychain:
    /// one makes the pair, the other is refused, and the pair is one caller's.
    @Test func racingCreatesEndWithOneCallersPair() async throws {
        defer { cleanUp() }
        for _ in 0..<5 {
            try keychain.deleteAll()
            let manager = KeyManager(keychain: keychain)
            let results = await withTaskGroup(of: Result<Data, any Error>.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        Result { try manager.createKeys() }.map { $0.databaseKeyData + $0.fileKey.withUnsafeBytes { Data($0) } }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            let made = results.compactMap { try? $0.get() }
            #expect(made.count == 1, "both callers made keys")
            let stored = try manager.loadKeys()
            #expect(made.contains(stored.databaseKeyData + stored.fileKey.withUnsafeBytes { Data($0) }), "a mixed or replaced pair")
            for case .failure(let error) in results {
                #expect(error as? KeyManagerError == .keysAlreadyExist)
            }
        }
    }

    /// `rotate` handed keys other than the archive's refuses and writes nothing.
    @Test func rotatingOtherKeysIsRefused() throws {
        defer { cleanUp() }
        let manager = KeyManager(keychain: keychain)
        let archive = try ArchiveSetup.createArchive(location, keyManager: manager)
        let before = try FileManager.default.contentsOfDirectory(atPath: location.root.path).sorted()
        #expect(throws: (any Error).self) { try ArchiveSetup.rotate(archive, keys: Self.otherKeys()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: location.root.path).sorted() == before)
        #expect(ArchiveSetup.recoveryState(archive) == .none)
    }

    /// A bundle beside the archive that carries the right archive ID but other
    /// keys is never confirmed.
    @Test func confirmingABundleOfOtherKeysIsRefused() throws {
        defer { cleanUp() }
        let manager = KeyManager(keychain: keychain)
        let archive = try ArchiveSetup.createArchive(location, keyManager: manager)
        let key = RecoveryKey.generate()
        try RecoveryBundle.write(Self.otherKeys(), archiveID: try archive.archiveID(), recoveryKey: key, to: location.root)
        #expect(throws: ArchiveSetupError.bundleMismatch) {
            try ArchiveSetup.confirm(archive, recoveryKey: key, typed: [0: key.groups[0], 1: key.groups[1]])
        }
        #expect(ArchiveSetup.recoveryState(archive) == .unconfirmed)
    }
}
