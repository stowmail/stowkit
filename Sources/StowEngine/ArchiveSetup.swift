import Foundation
import StowCore
import StowSecrets
import StowStore
import StowSync

public enum ArchiveSetupError: Error, Equatable, CustomStringConvertible {
    /// An archive exists but its keys are not in this Mac's Keychain.
    case archiveWithoutKeys(String)
    /// The recovery key has not been confirmed, so no real mail may be imported yet (D-007).
    case recoveryNotConfirmed
    case notAnArchive(String)
    /// The recovery bundle opened, but its keys belong to a different archive.
    case bundleMismatch

    public var description: String {
        switch self {
        case .archiveWithoutKeys(let path):
            "An archive exists at \(path) but its keys are not in this Mac's Keychain. If it came from another Mac, run `stowmail recover --archive \(path)` with its recovery key. New keys could never open it, so none were made."
        case .recoveryNotConfirmed:
            "Save your recovery key first. Run `stowmail recovery-key rotate` to see a new one and confirm it; until then no mail is imported."
        case .notAnArchive(let path): "There is no Stow archive at \(path)."
        case .bundleMismatch: "The recovery bundle's keys do not open the archive beside it. Nothing was changed."
        }
    }
}

/// Setting up an archive and its recovery key (Phase 2 step 1a, D-007, D-031).
///
/// The recovery key is made when the archive is, shown once, and must be
/// confirmed by typing two of its groups back before any real mail is
/// imported. Rotating makes a new one (the only way to see a key again) and
/// re-wraps the bundle; the archive keys themselves never change, so nothing
/// is re-encrypted.
public enum ArchiveSetup {
    static let confirmedKey = "recovery_confirmed_at"

    /// Creates the archive keys unless they exist, opens (or creates) the
    /// archive, and makes a recovery key when the archive has no confirmed one.
    /// Returns the new recovery key to show, if one was made.
    public static func initialise(_ location: ArchiveLocation, keyManager: KeyManager) throws -> (archive: Archive, recoveryKey: RecoveryKey?) {
        let keys: ArchiveKeys
        if try keyManager.keysExist() {
            keys = try keyManager.loadKeys()
        } else {
            guard !location.exists else { throw ArchiveSetupError.archiveWithoutKeys(location.root.path) }
            keys = try keyManager.createKeys()
        }
        let archive = try Archive.open(location, keys: keys)
        guard !isConfirmed(archive) || !RecoveryBundle.exists(in: location.root) else { return (archive, nil) }
        return (archive, try rotate(archive, keys: keys))
    }

    /// Makes a new recovery key and wraps the archive keys with it, replacing
    /// the old bundle. The new key is unconfirmed until `markConfirmed`.
    public static func rotate(_ archive: Archive, keys: ArchiveKeys) throws -> RecoveryKey {
        let recoveryKey = RecoveryKey.generate()
        try RecoveryBundle.write(keys, archiveID: try archive.archiveID(), recoveryKey: recoveryKey, to: archive.location.root)
        try archive.setMeta(confirmedKey, nil)
        return recoveryKey
    }

    /// Two different group numbers (0-based) to ask the user to type back.
    public static func confirmationGroups<G: RandomNumberGenerator>(using generator: inout G) -> (Int, Int) {
        let first = Int.random(in: 0..<RecoveryKey.groupCount, using: &generator)
        var second = Int.random(in: 0..<(RecoveryKey.groupCount - 1), using: &generator)
        if second >= first { second += 1 }
        return (min(first, second), max(first, second))
    }

    public static func markConfirmed(_ archive: Archive, at date: Date = Date()) throws {
        try archive.setMeta(confirmedKey, String(Int(date.timeIntervalSince1970)))
    }

    public static func isConfirmed(_ archive: Archive) -> Bool {
        (try? archive.meta(confirmedKey)) != nil
    }

    /// Sync, import and the daemon call this before writing real mail.
    public static func requireConfirmed(_ archive: Archive) throws {
        guard isConfirmed(archive), RecoveryBundle.exists(in: archive.location.root) else {
            throw ArchiveSetupError.recoveryNotConfirmed
        }
    }

    /// Restores the archive keys onto this Mac from the archive folder's
    /// recovery bundle (D-031). Checks the keys open that archive before saving
    /// them, and never replaces keys already in the Keychain. Returns the archive ID.
    @discardableResult
    public static func recover(archiveFolder: URL, recoveryKey: RecoveryKey, keyManager: KeyManager) throws -> String {
        let location = ArchiveLocation(root: archiveFolder)
        guard location.exists else { throw ArchiveSetupError.notAnArchive(archiveFolder.path) }
        let (keys, archiveID) = try RecoveryBundle.unwrap(in: location.root, with: recoveryKey)
        guard try !keyManager.keysExist() else { throw KeyManagerError.keysAlreadyExist }
        let archive = try Archive.open(location, keys: keys)
        guard try archive.archiveID() == archiveID else { throw ArchiveSetupError.bundleMismatch }
        try archive.database.close()
        try keyManager.installRecovered(keys)
        return archiveID
    }

    /// Moves Phase 1 account records from the Keychain into the archive (D-032),
    /// keeping their IDs so tokens and downloaded mail still match, then
    /// deletes the Keychain records. Tokens stay in the Keychain. Returns how many moved.
    @discardableResult
    public static func adoptKeychainAccounts(_ archive: Archive, registry: AccountRegistry) throws -> Int {
        let records = try registry.all()
        guard !records.isEmpty else { return 0 }
        let adopted = try ArchiveAccounts(archive: archive).adopt(records)
        for id in adopted where try ArchiveAccounts(archive: archive).record(id) != nil {
            try registry.forget(id)
        }
        return adopted.count
    }
}
