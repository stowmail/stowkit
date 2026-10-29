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
    /// The keys offered for a new recovery key are not the ones the archive was opened with.
    case keysNotThisArchives
    /// Fewer than two different groups were typed back.
    case tooFewGroups
    /// A typed group does not match the recovery key being confirmed.
    case groupMismatch
    /// The key being confirmed does not open the bundle beside the archive,
    /// for example one from an earlier attempt that a newer key replaced.
    case notCurrentRecoveryKey
    /// `create` was asked for while a confirmed recovery key exists.
    case recoveryAlreadyConfirmed

    public var description: String {
        switch self {
        case .archiveWithoutKeys(let path):
            "An archive exists at \(path) but its keys are not in this Mac's Keychain. If it came from another Mac, run `stowmail recover --archive \(path)` with its recovery key. New keys could never open it, so none were made."
        case .recoveryNotConfirmed:
            "Save your recovery key first. Run `stowmail recovery-key create` to make one and confirm it; until then no mail is imported."
        case .notAnArchive(let path): "There is no Stow archive at \(path)."
        case .bundleMismatch: "The recovery bundle's keys do not open the archive beside it. Nothing was changed."
        case .keysNotThisArchives:
            "The archive keys in this Mac's Keychain are not the ones this archive was opened with, so no recovery key was made. Nothing was changed."
        case .tooFewGroups: "Type two different groups of the recovery key to confirm it."
        case .groupMismatch: "That does not match. Check the groups you saved and try again."
        case .notCurrentRecoveryKey:
            "That recovery key has been replaced by a newer one, so it cannot be confirmed. Make a new key and confirm that one."
        case .recoveryAlreadyConfirmed:
            "This archive already has a confirmed recovery key. To replace it, run `stowmail recovery-key rotate`; the old key keeps working until the new one is confirmed."
        }
    }
}

/// Where an archive is with its recovery key (D-031, D-055).
public enum RecoveryState: Sendable, Equatable {
    /// No recovery bundle beside the archive, live or pending: no key has been made yet.
    case none
    /// A key was made but not typed back. It cannot be shown again, so the
    /// next step is a new key (`makeRecoveryKey`). Also a first key still
    /// waiting as `keys.recovery.pending` (D-480).
    case unconfirmed
    /// The key was typed back. Mail may be imported.
    case confirmed
}

/// Setting up an archive and its recovery key (Phase 2 step 1a, D-007, D-031).
///
/// The archive and its keys are made first (`createArchive`); accounts can be
/// added then. The recovery key is made later (`makeRecoveryKey`), shown once,
/// and must be confirmed by typing two of its groups back (`confirm`) before
/// any real mail is imported (D-055, D-084). Rotating makes a new one (the only
/// way to see a key again) and re-wraps the bundle; the archive keys themselves
/// never change, so nothing is re-encrypted.
///
/// A new key waits as `keys.recovery.pending` until it is confirmed (A-04,
/// D-480). The confirmation is recorded with the pending bundle's fingerprint
/// in one durable commit, and only then does the pending file replace
/// `keys.recovery`. Stopping anywhere leaves the old key opening the live
/// bundle, or the new one confirmed and promoted at the next writer open
/// (`finishConfirmedKey`).
public enum ArchiveSetup {
    static let confirmedKey = "recovery_confirmed_at"
    /// The fingerprint of the bundle that was confirmed (D-086). Empty when
    /// none was beside the archive; absent for confirmations made before it.
    static let confirmedBundleKey = "recovery_confirmed_bundle"

    /// The CLI's `init`: creates the archive and its keys, then makes a
    /// recovery key unless a confirmed one exists. Returns the new recovery
    /// key to show, if one was made.
    public static func initialise(_ location: ArchiveLocation, keyManager: KeyManager) throws -> (archive: Archive, recoveryKey: RecoveryKey?) {
        let archive = try createArchive(location, keyManager: keyManager)
        guard recoveryState(archive) != .confirmed else { return (archive, nil) }
        return (archive, try makeRecoveryKey(archive, keyManager: keyManager))
    }

    /// Creates the archive keys unless they exist, and opens (or creates) the
    /// archive. Makes no recovery key, so nothing can be imported yet (D-055).
    /// Refuses to make new keys for an archive that exists without them.
    public static func createArchive(_ location: ArchiveLocation, keyManager: KeyManager) throws -> Archive {
        // Never a new archive, or new keys, in a folder whose archive moved away (A-10).
        try location.refuseIfMoved()
        let keys: ArchiveKeys
        if try keyManager.keysExist() {
            keys = try keyManager.loadKeys()
        } else {
            guard !location.exists else { throw ArchiveSetupError.archiveWithoutKeys(location.root.path) }
            keys = try keyManager.createKeys()
        }
        return try Archive.open(location, keys: keys)
    }

    /// A confirmation counts only with the bundle it confirmed still beside the
    /// archive: a bundle replaced without a new confirmation, or a file copied
    /// in, reads as unconfirmed (D-086). A recorded fingerprint naming the
    /// pending bundle is a confirmed key not yet promoted, which still counts.
    public static func recoveryState(_ archive: Archive) -> RecoveryState {
        let root = archive.location.root
        let live = RecoveryBundle.exists(in: root)
        let pending = RecoveryBundle.exists(in: root, name: RecoveryBundle.pendingFileName)
        guard live || pending else { return .none }
        guard isConfirmed(archive) else { return .unconfirmed }
        let recorded: String?
        do {
            recorded = try archive.meta(confirmedBundleKey)
        } catch {
            return .unconfirmed
        }
        // Confirmed before D-086, which did not record the bundle: trusted as before.
        guard let recorded else { return live ? .confirmed : .unconfirmed }
        if live, recorded == (try? RecoveryBundle.fingerprint(in: root)) { return .confirmed }
        if pending, recorded == (try? RecoveryBundle.fingerprint(in: root, name: RecoveryBundle.pendingFileName)) { return .confirmed }
        return .unconfirmed
    }

    /// Whether a new key was made but never confirmed: the pending bundle is
    /// there and is not the confirmed one. The old key, if any, still works.
    public static func hasUnconfirmedNewKey(_ archive: Archive) -> Bool {
        let root = archive.location.root
        guard let pending = try? RecoveryBundle.fingerprint(in: root, name: RecoveryBundle.pendingFileName) else { return false }
        return (try? archive.meta(confirmedBundleKey)) != pending
    }

    /// Makes a new recovery key for the archive and returns it to show once.
    /// It waits beside the archive until confirmed; any earlier key keeps working until then.
    public static func makeRecoveryKey(_ archive: Archive, keyManager: KeyManager) throws -> RecoveryKey {
        try rotate(archive, keys: try keyManager.loadKeys())
    }

    /// Makes a new recovery key and wraps the archive keys with it as
    /// `keys.recovery.pending`, replacing any earlier pending one. The live
    /// bundle and its confirmation are left alone, so sync carries on and the
    /// old key keeps working until `confirm` (A-04, D-480).
    /// Refuses keys other than the ones the archive was opened with (A-09), so
    /// a Keychain changed meanwhile can never end up in the bundle.
    public static func rotate(_ archive: Archive, keys: ArchiveKeys) throws -> RecoveryKey {
        guard archive.isOpened(with: keys) else { throw ArchiveSetupError.keysNotThisArchives }
        let recoveryKey = RecoveryKey.generate()
        try RecoveryBundle.write(keys, archiveID: try archive.archiveID(), recoveryKey: recoveryKey, to: archive.location.root,
                                 name: RecoveryBundle.pendingFileName, sync: archive.diskSync)
        return recoveryKey
    }

    /// Finishes a confirmation that stopped between its commit and the rename:
    /// when the recorded fingerprint names the pending bundle, it replaces the
    /// live one. It writes, so callers hold the writer lock (D-035): the CLI's
    /// `openForWriting` and the scheduler's turn. Returns whether it promoted.
    @discardableResult
    public static func finishConfirmedKey(_ archive: Archive) throws -> Bool {
        let root = archive.location.root
        guard let pending = try? RecoveryBundle.fingerprint(in: root, name: RecoveryBundle.pendingFileName),
              isConfirmed(archive), try archive.meta(confirmedBundleKey) == pending else { return false }
        try RecoveryBundle.promotePending(in: root, sync: archive.diskSync)
        return true
    }

    /// Deletes a new key nobody confirmed (the prompt gave up, or the user
    /// quit), unless it is the confirmed one waiting to be promoted, which is
    /// promoted instead. The live bundle and its confirmation are untouched.
    public static func discardUnconfirmedKey(_ archive: Archive) throws {
        guard !(try finishConfirmedKey(archive)) else { return }
        guard RecoveryBundle.exists(in: archive.location.root, name: RecoveryBundle.pendingFileName) else { return }
        try RecoveryBundle.removePending(in: archive.location.root, sync: archive.diskSync)
    }

    /// Confirms the recovery key from groups the user typed back (group number,
    /// 0-based, to text). Needs two different groups, each matching, and the
    /// key must open the waiting bundle (or, with none waiting, the live one,
    /// as for a key an older build made), so a key from an earlier attempt
    /// cannot confirm a newer bundle. The key is never stored.
    ///
    /// The confirmation is made durable first, then the pending bundle
    /// replaces the live one (A-04). Callers hold the writer lock.
    public static func confirm(_ archive: Archive, recoveryKey: RecoveryKey, typed: [Int: String], at date: Date = Date()) throws {
        guard typed.count >= 2 else { throw ArchiveSetupError.tooFewGroups }
        for (group, text) in typed where !recoveryKey.groupMatches(group, typed: text) {
            throw ArchiveSetupError.groupMismatch
        }
        let root = archive.location.root
        let name = RecoveryBundle.exists(in: root, name: RecoveryBundle.pendingFileName) ? RecoveryBundle.pendingFileName : RecoveryBundle.fileName
        let fingerprint: String
        do {
            fingerprint = try RecoveryBundle.fingerprint(in: root, name: name)
        } catch RecoveryBundleError.missing {
            // The key's bundle was discarded (the prompt gave up) and no other is there.
            throw ArchiveSetupError.notCurrentRecoveryKey
        }
        let unwrapped: (keys: ArchiveKeys, archiveID: String)
        do {
            unwrapped = try RecoveryBundle.unwrap(in: root, name: name, with: recoveryKey)
        } catch RecoveryBundleError.wrongKey {
            throw ArchiveSetupError.notCurrentRecoveryKey
        }
        // The bundle checked must be the one recorded as confirmed.
        guard try RecoveryBundle.fingerprint(in: root, name: name) == fingerprint else { throw ArchiveSetupError.notCurrentRecoveryKey }
        // Same archive, and the very keys it was opened with (A-09).
        guard try archive.archiveID() == unwrapped.archiveID, archive.isOpened(with: unwrapped.keys) else {
            throw ArchiveSetupError.bundleMismatch
        }
        try record(archive, bundle: fingerprint, at: date)
        if name == RecoveryBundle.pendingFileName {
            try RecoveryBundle.promotePending(in: root, sync: archive.diskSync)
        }
    }

    /// Two different group numbers (0-based) to ask the user to type back.
    public static func confirmationGroups<G: RandomNumberGenerator>(using generator: inout G) -> (Int, Int) {
        let first = Int.random(in: 0..<RecoveryKey.groupCount, using: &generator)
        var second = Int.random(in: 0..<(RecoveryKey.groupCount - 1), using: &generator)
        if second >= first { second += 1 }
        return (min(first, second), max(first, second))
    }

    /// Marks the current key confirmed without checking it, promoting a
    /// waiting one first. Tests and setups that write their own bundle use it;
    /// the CLI and app use `confirm`.
    public static func markConfirmed(_ archive: Archive, at date: Date = Date()) throws {
        let root = archive.location.root
        if RecoveryBundle.exists(in: root, name: RecoveryBundle.pendingFileName) {
            try RecoveryBundle.promotePending(in: root, sync: archive.diskSync)
        }
        try record(archive, bundle: (try? RecoveryBundle.fingerprint(in: root)) ?? "", at: date)
    }

    /// Both rows in one commit that is on the drive before the caller renames anything.
    private static func record(_ archive: Archive, bundle fingerprint: String, at date: Date) throws {
        try archive.setMetaDurably([confirmedBundleKey: fingerprint, confirmedKey: String(Int(date.timeIntervalSince1970))])
    }

    /// The confirmation alone; callers use `recoveryState`, which also wants the bundle.
    static func isConfirmed(_ archive: Archive) -> Bool {
        (try? archive.meta(confirmedKey)) != nil
    }

    /// Sync, import and the daemon call this before writing real mail.
    public static func requireConfirmed(_ archive: Archive) throws {
        guard recoveryState(archive) == .confirmed else { throw ArchiveSetupError.recoveryNotConfirmed }
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
