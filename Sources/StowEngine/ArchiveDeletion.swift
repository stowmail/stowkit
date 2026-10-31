import Foundation
import GRDB
import StowCore
import StowSecrets
import StowStore

public enum ArchiveDeletionError: Error, Equatable, CustomStringConvertible {
    /// Another process holds the writer lock (D-035), usually the background sync.
    case busy
    /// No archive in the folder, and no unfinished deletion either.
    case notAnArchive(String)
    /// This Mac's Keychain has no archive keys under the service searched.
    case noKeys(String)
    /// The keys in the Keychain do not open the archive in this folder: they
    /// belong to another archive, whose keys must not be deleted.
    case keysNotThisArchives(String)

    public var description: String {
        switch self {
        case .busy:
            "Another Stow process is using the archive, probably the background sync, so nothing was deleted. Quit it, or stop the command-line background sync with `stowmail daemon uninstall`, and try again."
        case .notAnArchive(let path):
            "There is no Stow archive at \(path), so nothing was deleted."
        case .noKeys(let path):
            "This Mac's Keychain has no keys for the archive at \(path), so Stow cannot check it is the archive to delete. Nothing was deleted."
        case .keysNotThisArchives(let path):
            "The archive keys in this Mac's Keychain do not open the archive at \(path): they belong to another archive, and deleting them would make that one unreadable. Nothing more was deleted."
        }
    }
}

/// Deleting the whole archive (R17, UI-16, D-530), with the writer lock held throughout.
///
/// 0. `accounts`: every account is removed as `stowmail account remove` does
///    (D-032): its tokens or app-specific password deleted from the Keychain,
///    the account disconnected. The archive still works if it stops here.
/// 1. `marker`: `deleting.json` goes into the folder, flushed, naming a digest
///    of the keys (never the keys). From here every open, create or choice of
///    the folder is refused (`ArchiveLocationError.beingDeleted`), so a
///    half-deleted archive never looks empty and gets filled again.
/// 2. `database`: the database, its WAL and SHM.
/// 3. `files`: `raw/` and `attachments/`.
/// 4. `folderFiles`: `keys.recovery`, `keys.recovery.pending`, `rules.json`
///    and the Spotlight marker.
/// 5. `keys`: the two archive key items, only once they are known to be this archive's.
/// 6. `lockFile`: `.writer.lock`.
/// 7. `finish`: the marker, then the folder itself if nothing else is in it.
///
/// Besides the accounts' sign-ins in step 0, nothing outside the folder and its
/// two key items is touched. Stopped anywhere, the folder is either the working
/// archive (before step 1) or refused everywhere until `delete` runs again,
/// which carries on from where it stopped.
public enum ArchiveDeletion {
    public enum Step: String, CaseIterable, Sendable {
        case accounts, marker, database, files, folderFiles, keys, lockFile, finish
    }

    public struct Outcome: Sendable, Equatable {
        /// The accounts that were still connected, now removed; empty when carrying on after a stop.
        public var removedAccounts: [Account]
        /// False when the Keychain held no keys, or keys that cannot be shown to be this archive's.
        public var deletedKeys: Bool
        /// False when the folder holds something Stow did not make, which stays.
        public var removedFolder: Bool
    }

    struct Marker: Codable {
        var format = "ee.getstow.deleting"
        var version = 1
        /// `ArchiveKeys.digest` in hex: lets an unfinished deletion delete only these keys.
        var keys: String
        var startedAt: Date
    }

    /// Deletes the archive at `location` and its keys from `keyManager`'s
    /// Keychain. `willRun` is called before each step; tests throw from it to
    /// stop there.
    public static func delete(
        _ location: ArchiveLocation, keyManager: KeyManager, sync: DiskSync = .system,
        willRun: (Step) throws -> Void = { _ in }
    ) throws -> Outcome {
        if let destination = location.movedTo() { throw ArchiveLocationError.moved(destination) }
        let resuming = location.isBeingDeleted
        guard resuming || location.exists else { throw ArchiveDeletionError.notAnArchive(location.root.path) }
        let lock: ArchiveLock
        do {
            lock = try ArchiveLock.acquire(location)
        } catch ArchiveLockError.busy {
            throw ArchiveDeletionError.busy
        }
        defer { lock.release() }

        let deleteKeys: Bool
        var removedAccounts: [Account] = []
        if resuming {
            deleteKeys = try keysToDeleteWhenResuming(location, keyManager: keyManager)
        } else {
            let keys = try thisArchivesKeys(location, keyManager: keyManager)
            try willRun(.accounts)
            removedAccounts = try removeAccounts(location, keys: keys, keychain: keyManager.keychain)
            try willRun(.marker)
            try writeMarker(location, keys: keys.digest, sync: sync)
            deleteKeys = true
        }

        try willRun(.database)
        let database = location.databaseURL.path
        try remove([location.databaseURL, URL(fileURLWithPath: database + "-wal"), URL(fileURLWithPath: database + "-shm")])
        try sync.flushFolder(location.root)

        try willRun(.files)
        try remove([location.rawDirectory, location.attachmentsDirectory])

        try willRun(.folderFiles)
        try remove([location.recoveryBundleURL, location.root.appendingPathComponent(RecoveryBundle.pendingFileName),
                    location.root.appendingPathComponent("rules.json"), location.root.appendingPathComponent(".metadata_never_index")])
        try sync.flushFolder(location.root)

        try willRun(.keys)
        if deleteKeys { try keyManager.deleteKeys() }

        try willRun(.lockFile)
        try remove([location.lockURL])

        try willRun(.finish)
        try remove([location.deletingMarkerURL])
        try sync.flushFolder(location.root)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: location.root.path)) ?? []
        var removedFolder = false
        if left.allSatisfy({ $0 == ".DS_Store" }) {
            try remove(left.map { location.root.appendingPathComponent($0) })
            removedFolder = rmdir(location.root.path) == 0
        }
        return Outcome(removedAccounts: removedAccounts, deletedKeys: deleteKeys, removedFolder: removedFolder)
    }

    /// `stowmail account remove` for every account: each one's tokens and
    /// app-specific password deleted (absent ones too), connected ones
    /// disconnected. Returns the accounts that were connected.
    static func removeAccounts(_ location: ArchiveLocation, keys: ArchiveKeys, keychain: KeychainStore) throws -> [Account] {
        let archive = try Archive.open(location, keys: keys)
        defer { try? archive.database.close() }
        let accounts = ArchiveAccounts(archive: archive)
        let tokens = TokenStore(keychain: keychain), passwords = PasswordStore(keychain: keychain)
        var removed: [Account] = []
        for record in try accounts.all() {
            try tokens.delete(for: record.account.id)
            try passwords.delete(for: record.account.id)
            guard record.isConnected else { continue }
            try accounts.disconnect(record.account.id)
            removed.append(record.account)
        }
        return removed
    }

    /// The Keychain's keys, once they are shown to open this folder's database.
    static func thisArchivesKeys(_ location: ArchiveLocation, keyManager: KeyManager) throws -> ArchiveKeys {
        let keys: ArchiveKeys
        do {
            keys = try keyManager.loadKeys()
        } catch KeyManagerError.keysMissing {
            throw ArchiveDeletionError.noKeys(location.root.path)
        }
        guard try opens(location, with: keys) else { throw ArchiveDeletionError.keysNotThisArchives(location.root.path) }
        return keys
    }

    /// Whether `keys` open the database: a wrong key fails as "not a database"
    /// on the first read (`EncryptedDatabase`). Any other failure is thrown.
    static func opens(_ location: ArchiveLocation, with keys: ArchiveKeys) throws -> Bool {
        do {
            let database = try EncryptedDatabase.open(at: location.databaseURL, key: KeyBuffer(keys.databaseKey), readOnly: true)
            try database.close()
            return true
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            return false
        }
    }

    /// Carrying on after a stop: the keys go only if they still open the
    /// database, or, with the database gone, if they are the ones the marker names.
    static func keysToDeleteWhenResuming(_ location: ArchiveLocation, keyManager: KeyManager) throws -> Bool {
        let keys: ArchiveKeys
        do {
            keys = try keyManager.loadKeys()
        } catch KeyManagerError.keysMissing {
            return false
        }
        if location.exists {
            guard try opens(location, with: keys) else { throw ArchiveDeletionError.keysNotThisArchives(location.root.path) }
            return true
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: location.deletingMarkerURL.path),
              let marker = try? decoder.decode(Marker.self, from: data),
              let recorded = KeysDigest(hex: marker.keys) else { return false }
        return recorded.matches(keys.digest)
    }

    static func writeMarker(_ location: ArchiveLocation, keys: KeysDigest, sync: DiskSync) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try location.writeMarker(try encoder.encode(Marker(keys: keys.hex, startedAt: Date())), to: location.deletingMarkerURL, sync: sync)
    }

    /// Removes each item that is there; a missing one was removed before a stop.
    static func remove(_ urls: [URL]) throws {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
