import Foundation
import GRDB
import StowCore
import StowSecrets
import StowStore

public enum PreUpgradeRestoreError: Error, Equatable, CustomStringConvertible {
    /// No copy from before an update is recorded, or its file is gone (expired after 7 days).
    case noCopy
    /// Another Stow process holds the writer lock or is updating the archive.
    case busy
    /// The copy does not open with this archive's key or fails SQLite's check.
    case copyDamaged

    public var description: String {
        switch self {
        case .noCopy:
            "There is no copy from before an update to put back. Stow keeps one for 7 days after an update changes the archive's format."
        case .busy:
            "Another Stow process is using the archive, probably the background sync or the app, so nothing was changed. Quit the app, stop the background sync with `stowmail daemon uninstall`, and try again."
        case .copyDamaged:
            "The copy from before the update did not pass its check, so nothing was changed."
        }
    }
}

/// `stowmail restore-pre-upgrade` (D-606 item 5, D-608): puts back the copy of
/// the database made before the last format migration.
///
/// 1. Takes the writer lock and `.migration.lock` without waiting, so nothing
///    else writes or migrates while the database is swapped.
/// 2. Checks the copy opens with the archive's key and passes `integrity_check`.
/// 3. Folds the current database's WAL into it, then renames it to
///    `replaced-by-restore-<date>.db`: kept aside 7 days, like the copy.
/// 4. Renames the copy to `archive.sqlite`, clears the copy's keys in it and
///    records the set-aside database there (`replaced_by_restore`).
/// 5. Runs the full archive check (D-042) read-only, and lists messages whose
///    files are gone: tidy-up removed them after the copy was made.
///
/// Command line only; nothing in the app offers it (D-606).
public enum PreUpgradeRestore {
    public struct Plan: Sendable, Equatable {
        public var copyName: String
        public var from: String
        public var to: String
        public var migratedAt: Date
    }

    public struct Outcome: Sendable, Equatable {
        /// The database that was in use, now kept aside for 7 days.
        public var replacedName: String
        public var report: ArchiveVerifyReport
        /// Messages the restored database lists whose stored file is gone.
        public var missingFiles: [StoredMessageID]
    }

    /// What a restore would put back, read without changing anything.
    public static func plan(_ location: ArchiveLocation, keys: ArchiveKeys) throws -> Plan {
        let archive = try Archive.open(location, keys: keys, readOnly: true)
        defer { try? archive.database.close() }
        guard let copy = try PreUpgradeCopy.copy(archive), let from = copy.from, let to = copy.to else {
            throw PreUpgradeRestoreError.noCopy
        }
        return Plan(copyName: copy.name, from: from, to: to, migratedAt: copy.madeAt)
    }

    public static func restore(_ location: ArchiveLocation, keys: ArchiveKeys, now: Date = Date(),
                               sync: DiskSync = .system) throws -> Outcome {
        try location.refuseIfMoved()
        let writer: ArchiveLock, migration: ArchiveLock
        do {
            writer = try ArchiveLock.acquire(location)
        } catch ArchiveLockError.busy {
            throw PreUpgradeRestoreError.busy
        }
        defer { writer.release() }
        do {
            migration = try ArchiveLock.acquire(url: location.migrationLockURL)
        } catch ArchiveLockError.busy {
            throw PreUpgradeRestoreError.busy
        }
        defer { migration.release() }

        let plan = try plan(location, keys: keys)
        let copyURL = location.root.appendingPathComponent(plan.copyName)
        guard PreUpgradeCopy.check(copyURL, key: KeyBuffer(keys.databaseKey), applied: nil) else {
            throw PreUpgradeRestoreError.copyDamaged
        }

        let databaseURL = location.databaseURL
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal"), shm = URL(fileURLWithPath: databaseURL.path + "-shm")
        let previousReplaced: String?
        do {
            let current = try EncryptedDatabase.open(at: databaseURL, key: KeyBuffer(keys.databaseKey))
            previousReplaced = try current.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = ?", arguments: [PreUpgradeCopy.replacedKey])
            }
            try current.writeWithoutTransaction { db in _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            try current.close()
        }
        // Anything left in the WAL means another connection still has the database open.
        if let size = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? NSNumber, size.int64Value > 0 {
            throw PreUpgradeRestoreError.busy
        }
        try? FileManager.default.removeItem(at: wal)
        try? FileManager.default.removeItem(at: shm)

        let replacedName = name(for: now, in: location)
        let replaced = location.root.appendingPathComponent(replacedName)
        try sync.rename(databaseURL, to: replaced)
        try sync.rename(copyURL, to: databaseURL)
        try sync.flushFolder(location.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replaced.path)

        // Recorded in the restored database, which knows nothing of either file yet.
        do {
            let restored = try EncryptedDatabase.open(at: databaseURL, key: KeyBuffer(keys.databaseKey))
            try restored.write { db in
                try db.execute(sql: "DELETE FROM archive_meta WHERE key IN (?, ?)",
                               arguments: [PreUpgradeCopy.copyKey, PreUpgradeCopy.migratedAtKey])
                for (key, value) in [(PreUpgradeCopy.replacedKey, replacedName),
                                     (PreUpgradeCopy.replacedAtKey, String(Int(now.timeIntervalSince1970)))] {
                    try db.execute(sql: """
                        INSERT INTO archive_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value
                        """, arguments: [key, value])
                }
            }
            try restored.close()
        }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: databaseURL.path + suffix) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path + suffix)
        }
        // One set-aside database at a time: an earlier restore's goes now.
        if let previousReplaced, previousReplaced != replacedName, previousReplaced.hasPrefix("replaced-by-restore-"),
           previousReplaced.hasSuffix(".db"), !previousReplaced.contains("/") {
            PreUpgradeCopy.removeDatabaseFiles(location.root.appendingPathComponent(previousReplaced))
        }

        // Not `Archive.open`: a writable open would migrate the restored database
        // straight back, and FTS5's check runs as a write, so a read-only open cannot verify.
        let archive = Archive(location: location, database: try EncryptedDatabase.open(at: databaseURL, key: KeyBuffer(keys.databaseKey)),
                              keys: keys, diskSync: sync)
        defer { try? archive.database.close() }
        let report = try ArchiveVerifier(archive: archive).run()
        let missing = try report.failedMessages.filter { id in
            let hash = try archive.database.read { db in
                try Data.fetchOne(db, sql: "SELECT raw_hash FROM messages WHERE id = ?", arguments: [id])
            }
            return hash.map { !archive.rawFiles.exists($0) } ?? false
        }
        return Outcome(replacedName: replacedName, report: report, missingFiles: missing)
    }

    /// `replaced-by-restore-<yyyy-MM-dd>.db`, with the time added if a file of that name is already there.
    static func name(for date: Date, in location: ArchiveLocation) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = "replaced-by-restore-\(formatter.string(from: date)).db"
        guard FileManager.default.fileExists(atPath: location.root.appendingPathComponent(day).path) else { return day }
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "replaced-by-restore-\(formatter.string(from: date)).db"
    }
}
