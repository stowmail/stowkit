import CryptoKit
import Foundation
import Testing
@testable import StowSecrets

/// D-007, D-031: the recovery key and the key bundle it unlocks.
@Suite struct RecoveryKeyTests {
    @Test func displayIsFourteenGroupsOfFourAndReadsBack() throws {
        let key = RecoveryKey.generate()
        #expect(key.groups.count == 14)
        #expect(key.groups.allSatisfy { $0.count == 4 })
        #expect(key.displayString.count == 56 + 13)
        #expect(try RecoveryKey(key.displayString) == key)
        // Case, dashes and spaces do not matter.
        #expect(try RecoveryKey(key.displayString.lowercased().replacingOccurrences(of: "-", with: " ")) == key)
    }

    @Test func lookAlikeLettersReadAsDigits() throws {
        // Find a key whose text has a 1 and a 0 in it, then type them as l, I and O.
        var key = RecoveryKey.generate()
        while !(key.displayString.contains("1") && key.displayString.contains("0")) { key = RecoveryKey.generate() }
        let typed = key.displayString.replacingOccurrences(of: "1", with: "l").replacingOccurrences(of: "0", with: "O")
        #expect(try RecoveryKey(typed) == key)
    }

    @Test func aTypingMistakeIsCaught() throws {
        let key = RecoveryKey.generate()
        var characters = Array(key.displayString)
        let index = characters.firstIndex { $0 != "-" }!
        characters[index] = characters[index] == "A" ? "B" : "A"
        #expect(throws: RecoveryKeyError.self) { try RecoveryKey(String(characters)) }
        #expect(throws: RecoveryKeyError.wrongLength(55)) { try RecoveryKey(String(key.displayString.dropLast())) }
        #expect(throws: RecoveryKeyError.invalidCharacter("U")) { try RecoveryKey("U" + key.displayString.dropFirst()) }
    }

    @Test func groupsAreCheckedWhateverTheTyping() {
        let key = RecoveryKey.generate()
        let third = key.groups[2]
        #expect(key.groupMatches(2, typed: third.lowercased()))
        #expect(key.groupMatches(2, typed: " \(third) "))
        #expect(!key.groupMatches(3, typed: third) || key.groups[3] == third)
        #expect(!key.groupMatches(20, typed: third))
    }

    func keys() -> ArchiveKeys {
        ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stow-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func bundleUnwrapsWithItsKeyOnly() throws {
        let archive = try folder()
        defer { try? FileManager.default.removeItem(at: archive) }
        let original = keys()
        let recovery = RecoveryKey.generate()
        try RecoveryBundle.write(original, archiveID: "archive-1", recoveryKey: recovery, to: archive)

        let (unwrapped, id) = try RecoveryBundle.unwrap(in: archive, with: recovery)
        #expect(id == "archive-1")
        #expect(unwrapped.databaseKeyData == original.databaseKeyData)
        #expect(unwrapped.fileKey.withUnsafeBytes { Data($0) } == original.fileKey.withUnsafeBytes { Data($0) })
        #expect(throws: RecoveryBundleError.wrongKey) { try RecoveryBundle.unwrap(in: archive, with: RecoveryKey.generate()) }

        let file = archive.appendingPathComponent(RecoveryBundle.fileName)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        // The bundle holds no key in the clear.
        let text = try Data(contentsOf: file)
        #expect(text.range(of: original.databaseKeyData) == nil)
        #expect(text.range(of: Data(original.databaseKeyData.base64EncodedString().utf8)) == nil)
    }

    @Test func aBundleCannotBeMovedToAnotherArchive() throws {
        let archive = try folder()
        defer { try? FileManager.default.removeItem(at: archive) }
        let recovery = RecoveryKey.generate()
        try RecoveryBundle.write(keys(), archiveID: "archive-1", recoveryKey: recovery, to: archive)
        let file = archive.appendingPathComponent(RecoveryBundle.fileName)
        // Relabel it for another archive: the archive ID is authenticated, so it no longer opens.
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "archive-1", with: "archive-2")
        try edited.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: RecoveryBundleError.wrongKey) { try RecoveryBundle.unwrap(in: archive, with: recovery) }
    }

    @Test func rotatingReplacesTheBundleAndTheOldKeyStopsWorking() throws {
        let archive = try folder()
        defer { try? FileManager.default.removeItem(at: archive) }
        let original = keys()
        let first = RecoveryKey.generate()
        try RecoveryBundle.write(original, archiveID: "a", recoveryKey: first, to: archive)
        let second = RecoveryKey.generate()
        try RecoveryBundle.write(original, archiveID: "a", recoveryKey: second, to: archive)
        #expect(throws: RecoveryBundleError.wrongKey) { try RecoveryBundle.unwrap(in: archive, with: first) }
        #expect(try RecoveryBundle.unwrap(in: archive, with: second).keys.databaseKeyData == original.databaseKeyData)
        #expect(throws: RecoveryBundleError.missing) { try RecoveryBundle.unwrap(in: archive.appendingPathComponent("nope"), with: second) }
    }

    @Test func recoveredKeysNeverReplaceExistingOnes() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let manager = KeyManager(keychain: keychain)
        let recovered = keys()
        try manager.installRecovered(recovered)
        #expect(try manager.loadKeys().databaseKeyData == recovered.databaseKeyData)
        #expect(throws: KeyManagerError.keysAlreadyExist) { try manager.installRecovered(keys()) }
        #expect(try manager.loadKeys().databaseKeyData == recovered.databaseKeyData)
    }
}
