import Foundation
import GRDB
import StowCore
import StowSecrets

/// What `Archive.open` migrates with, and what the copy before a migration
/// reads from outside (D-606). `.standard` is this build's migrations, the
/// clock and the disk's real free space. Tests add migrations that are never
/// shipped, move the clock and pretend the disk is full.
public struct ArchiveUpgrade: Sendable {
    /// A migration registered after this build's own, oldest first.
    public struct Migration: Sendable {
        public let identifier: String
        public let migrate: @Sendable (Database) throws -> Void
        public init(identifier: String, migrate: @escaping @Sendable (Database) throws -> Void) {
            self.identifier = identifier
            self.migrate = migrate
        }
    }

    public var added: [Migration]
    public var now: @Sendable () -> Date
    /// Free space on the archive's disk, as Finder counts it; nil when the disk cannot say.
    public var availableBytes: @Sendable (URL) -> Int64?
    /// Runs on the finished copy, still under its temporary name, just before its check.
    public var willCheckCopy: @Sendable (URL) throws -> Void
    /// How long an opener waits for another one that is migrating the same archive.
    public var lockWait: TimeInterval

    public init(adding added: [Migration] = [], now: @escaping @Sendable () -> Date = { Date() },
                availableBytes: @escaping @Sendable (URL) -> Int64? = { ArchiveLocation.checkFolder($0).availableBytes },
                willCheckCopy: @escaping @Sendable (URL) throws -> Void = { _ in }, lockWait: TimeInterval = 600) {
        self.added = added
        self.now = now
        self.availableBytes = availableBytes
        self.willCheckCopy = willCheckCopy
        self.lockWait = lockWait
    }

    public static let standard = ArchiveUpgrade()

    /// Every migration identifier, oldest first.
    var identifiers: [String] { ArchiveSchema.migrationIdentifiers + added.map(\.identifier) }

    var migrator: DatabaseMigrator {
        var migrator = ArchiveSchema.migrator
        for migration in added { migrator.registerMigration(migration.identifier, migrate: migration.migrate) }
        return migrator
    }
}

/// The copy of the database made before a format migration (D-606), and the
/// database a restore set aside (D-608). Both sit in the archive folder,
/// encrypted with the archive's key, 0600, one of each at most, and go 7 days
/// after they were made. `raw/` and `attachments/` are never copied: no
/// migration changes them (D-202).
public enum PreUpgradeCopy {
    /// `archive_meta` keys (no schema change, as D-550): the copy's file name,
    /// and when the migration it was made for finished (Unix seconds).
    public static let copyKey = "pre_upgrade_copy"
    public static let migratedAtKey = "pre_upgrade_migrated_at"
    /// The database `stowmail restore-pre-upgrade` set aside, and when (D-608).
    public static let replacedKey = "replaced_by_restore"
    public static let replacedAtKey = "replaced_by_restore_at"
    public static let keptFor: TimeInterval = 7 * 86_400

    static let copyPrefix = "pre-upgrade-"
    static let replacedPrefix = "replaced-by-restore-"
    static let temporaryPrefix = ".tmp-pre-upgrade-"

    /// Free space the copy needs (D-607): the database and its WAL, plus a
    /// fifth of that or 100 MB, whichever is more, for the migration's own
    /// writes and so the disk is not run to nothing.
    public static func needed(databaseBytes: Int64) -> Int64 {
        databaseBytes + max(databaseBytes / 5, 100_000_000)
    }

    /// Whether `name` is one of the files this type makes, so a name read from
    /// the database can never point anywhere else.
    static func isKeptAside(_ name: String) -> Bool {
        (name.hasPrefix(copyPrefix) || name.hasPrefix(replacedPrefix)) && name.hasSuffix(".db")
            && !name.contains("/") && !name.contains("..")
    }

    // MARK: - Before a migration

    static func applied(_ db: Database, upgrade: ArchiveUpgrade) throws -> Set<String> {
        try db.tableExists("grdb_migrations") ? try upgrade.migrator.appliedIdentifiers(db) : []
    }

    static func hasOutstanding(_ db: Database, upgrade: ArchiveUpgrade) throws -> Bool {
        let applied = try applied(db, upgrade: upgrade)
        return upgrade.identifiers.contains { !applied.contains($0) }
    }

    /// The versions on either side of the outstanding migrations, when the
    /// archive already has some applied (a brand-new archive needs no copy).
    static func pendingUpgrade(_ db: Database, upgrade: ArchiveUpgrade) throws -> (from: String, to: String)? {
        let identifiers = upgrade.identifiers
        let applied = try applied(db, upgrade: upgrade)
        guard !applied.isEmpty, identifiers.contains(where: { !applied.contains($0) }),
              let from = identifiers.last(where: applied.contains), let to = identifiers.last else { return nil }
        return (from, to)
    }

    /// Applies every outstanding migration, copying the database first when
    /// the archive already holds an earlier format. With nothing outstanding
    /// this is one read. Otherwise it holds `.migration.lock`, so of two
    /// openers at once only one copies and migrates; the other waits, then
    /// finds nothing left to do (D-609).
    static func migrate(_ database: DatabasePool, location: ArchiveLocation, keys: ArchiveKeys,
                        upgrade: ArchiveUpgrade, diskSync: DiskSync) throws {
        guard try database.read({ try hasOutstanding($0, upgrade: upgrade) }) else { return }
        let lock = try ArchiveLock.acquire(url: location.migrationLockURL, wait: upgrade.lockWait)
        defer { lock.release() }
        // Read again under the lock: another opener may have finished meanwhile.
        guard try database.read({ try hasOutstanding($0, upgrade: upgrade) }) else { return }
        guard let (from, to) = try database.read({ try pendingUpgrade($0, upgrade: upgrade) }) else {
            try upgrade.migrator.migrate(database)
            return
        }

        let name = "\(copyPrefix)\(from)-to-\(to).db"
        let needed = needed(databaseBytes: fileSize(location.databaseURL) + fileSize(walURL(location.databaseURL)))
        // Before anything is written: the archive stays at its current format.
        if let free = upgrade.availableBytes(location.root), free < needed {
            throw ArchiveError.notEnoughSpaceToUpgrade(needed: needed)
        }

        removeTemporaryCopies(location)
        let applied = try database.read { db in try applied(db, upgrade: upgrade) }
        // The last writes into the main file first (the D-501 lesson); the backup reads through the WAL anyway.
        try database.writeWithoutTransaction { db in _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let temporary = location.root.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).db")
        do {
            try makeCopy(of: database, at: temporary, key: KeyBuffer(keys.databaseKey), diskSync: diskSync)
            try upgrade.willCheckCopy(temporary)
            guard check(temporary, key: KeyBuffer(keys.databaseKey), applied: applied) else {
                throw ArchiveError.upgradeCopyFailedCheck
            }
            try diskSync.rename(temporary, to: location.root.appendingPathComponent(name))
            try diskSync.flushFolder(location.root)
        } catch {
            removeDatabaseFiles(temporary)
            throw error
        }

        // The previous copy goes only now that the new one has passed its check.
        let previous = try database.read { db in try meta(db, copyKey) }
        if let previous, previous != name, isKeptAside(previous) {
            removeDatabaseFiles(location.root.appendingPathComponent(previous))
        }

        try upgrade.migrator.migrate(database)
        let finished = String(Int(upgrade.now().timeIntervalSince1970))
        try database.write { db in
            try setMeta(db, copyKey, name)
            try setMeta(db, migratedAtKey, finished)
        }
    }

    /// A consistent copy through SQLite's online backup, into a new file with
    /// the same key and an ordinary rollback journal, flushed with `F_FULLFSYNC` (D-607).
    static func makeCopy(of database: DatabasePool, at url: URL, key: KeyBuffer, diskSync: DiskSync) throws {
        let copy = try DatabaseQueue(path: url.path, configuration: keyed(key, readOnly: false))
        do {
            try database.backup(to: copy)
            // The backup brings the original's WAL flag; the copy is one plain file.
            try copy.writeWithoutTransaction { db in _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") }
            try copy.close()
        } catch {
            try? copy.close()
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DiskSyncError.flushFailed(errno) }
        defer { close(descriptor) }
        try diskSync.flushFile(descriptor, path: url.path)
    }

    /// Opens with `key`, passes `integrity_check`, and, when `applied` is
    /// given, records exactly those migrations.
    public static func check(_ url: URL, key: KeyBuffer, applied: Set<String>?) -> Bool {
        do {
            let copy = try DatabaseQueue(path: url.path, configuration: keyed(key, readOnly: true))
            defer { try? copy.close() }
            return try copy.read { db in
                guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"] else { return false }
                guard let applied else { return true }
                return try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")) == applied
            }
        } catch {
            return false
        }
    }

    static func keyed(_ key: KeyBuffer, readOnly: Bool) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readOnly
        configuration.busyMode = .timeout(30)
        configuration.prepareDatabase { db in try EncryptedDatabase.applyKey(key, to: db) }
        return configuration
    }

    // MARK: - After 7 days

    /// Deletes the copy, and the database a restore set aside, once 7 days
    /// have passed since each was made, and clears their keys. Runs at every
    /// writable open; a file already gone is fine.
    static func expire(_ database: DatabasePool, location: ArchiveLocation, now: Date) throws {
        for (nameKey, timeKey) in [(copyKey, migratedAtKey), (replacedKey, replacedAtKey)] {
            let (name, made) = try database.read { db in (try meta(db, nameKey), try meta(db, timeKey)) }
            guard let name, let seconds = made.flatMap(Int.init),
                  now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(seconds))) > keptFor else { continue }
            if isKeptAside(name) { removeDatabaseFiles(location.root.appendingPathComponent(name)) }
            try database.write { db in
                try setMeta(db, nameKey, nil)
                try setMeta(db, timeKey, nil)
            }
        }
    }

    // MARK: - For doctor and the restore

    public struct Kept: Sendable, Equatable {
        public var name: String
        public var url: URL
        /// The versions either side, read from the copy's name; nil for a set-aside database.
        public var from: String?
        public var to: String?
        public var madeAt: Date
        public var keptUntil: Date { madeAt.addingTimeInterval(PreUpgradeCopy.keptFor) }
    }

    /// The copy before the last migration, if it is recorded and still on disk.
    public static func copy(_ archive: Archive) throws -> Kept? {
        try kept(archive, nameKey: copyKey, timeKey: migratedAtKey)
    }

    /// The database a restore set aside, if it is recorded and still on disk.
    public static func replaced(_ archive: Archive) throws -> Kept? {
        try kept(archive, nameKey: replacedKey, timeKey: replacedAtKey)
    }

    static func kept(_ archive: Archive, nameKey: String, timeKey: String) throws -> Kept? {
        let (name, made) = try archive.database.read { db in (try meta(db, nameKey), try meta(db, timeKey)) }
        guard let name, isKeptAside(name), let seconds = made.flatMap(Int.init) else { return nil }
        let url = archive.location.root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var versions: [String] = []
        if name.hasPrefix(copyPrefix) {
            versions = String(name.dropFirst(copyPrefix.count).dropLast(3)).components(separatedBy: "-to-")
        }
        return Kept(name: name, url: url, from: versions.count == 2 ? versions[0] : nil, to: versions.count == 2 ? versions[1] : nil,
                    madeAt: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// What the next writable open would refuse for lack of space, read
    /// without changing anything (`stowmail doctor`).
    public static func spaceProblem(_ archive: Archive, upgrade: ArchiveUpgrade = .standard) throws -> ArchiveError? {
        guard try archive.database.read({ try pendingUpgrade($0, upgrade: upgrade) }) != nil else { return nil }
        let databaseURL = archive.location.databaseURL
        let needed = needed(databaseBytes: fileSize(databaseURL) + fileSize(walURL(databaseURL)))
        guard let free = upgrade.availableBytes(archive.location.root), free < needed else { return nil }
        return .notEnoughSpaceToUpgrade(needed: needed)
    }

    // MARK: - Files

    static func walURL(_ url: URL) -> URL { URL(fileURLWithPath: url.path + "-wal") }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The file and anything SQLite keeps beside it.
    public static func removeDatabaseFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Copies a stopped opener left under their temporary names.
    static func removeTemporaryCopies(_ location: ArchiveLocation) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: location.root.path)) ?? []
        for name in names where name.hasPrefix(temporaryPrefix) {
            try? FileManager.default.removeItem(at: location.root.appendingPathComponent(name))
        }
    }

    static func meta(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = ?", arguments: [key])
    }

    static func setMeta(_ db: Database, _ key: String, _ value: String?) throws {
        if let value {
            try db.execute(sql: """
                INSERT INTO archive_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM archive_meta WHERE key = ?", arguments: [key])
        }
    }
}

extension ArchiveLocation {
    /// Held only while a format migration and its copy run (D-609). Separate
    /// from `.writer.lock`, which some callers already hold when they open.
    public var migrationLockURL: URL { root.appendingPathComponent(".migration.lock") }

    /// The copy before a migration, a database a restore set aside, and any
    /// half-made copy, with SQLite's files beside them: they go wherever the archive goes.
    public func keptAsideDatabaseFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter {
            $0.hasPrefix(PreUpgradeCopy.copyPrefix) || $0.hasPrefix(PreUpgradeCopy.replacedPrefix)
                || $0.hasPrefix(PreUpgradeCopy.temporaryPrefix)
        }.sorted().map { root.appendingPathComponent($0) }
    }
}
