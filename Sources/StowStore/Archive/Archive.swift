import Foundation
import GRDB
import StowCore
import StowSecrets

/// An open archive: the encrypted database plus the encrypted file stores.
///
/// `Archive.open` prepares the folder (0700, not cloud-synced), opens the
/// database with SQLCipher and applies outstanding migrations.
public final class Archive: Sendable {
    public let location: ArchiveLocation
    public let database: DatabasePool
    public let rawFiles: EncryptedFileStore
    public let attachmentFiles: EncryptedFileStore
    /// How files and commits are flushed to disk; tests pass one that records the order.
    public let diskSync: DiskSync
    /// A digest of the keys this archive was opened with, not the keys (A-09, D-486).
    let keysDigest: KeysDigest

    public init(location: ArchiveLocation, database: DatabasePool, keys: ArchiveKeys, diskSync: DiskSync = .system) {
        self.location = location
        self.database = database
        self.diskSync = diskSync
        keysDigest = keys.digest
        rawFiles = EncryptedFileStore(directory: location.rawDirectory, kind: .raw, keys: keys, diskSync: diskSync)
        attachmentFiles = EncryptedFileStore(directory: location.attachmentsDirectory, kind: .attachment, keys: keys, diskSync: diskSync)
    }

    public static func open(_ location: ArchiveLocation, keys: ArchiveKeys, readOnly: Bool = false,
                            diskSync: DiskSync = .system) throws -> Archive {
        if !readOnly { try location.prepare() }
        let database = try EncryptedDatabase.open(at: location.databaseURL, key: keys.databaseKeyData, readOnly: readOnly)
        if !readOnly {
            try ArchiveSchema.migrate(database)
            try database.write { db in
                let now = String(Int(Date().timeIntervalSince1970))
                try db.execute(sql: "INSERT INTO archive_meta (key, value) VALUES ('archive_id', ?) ON CONFLICT DO NOTHING",
                               arguments: [UUID().uuidString.lowercased()])
                try db.execute(sql: "INSERT INTO archive_meta (key, value) VALUES ('created_at', ?) ON CONFLICT DO NOTHING",
                               arguments: [now])
            }
            secureDatabaseFiles(location)
        }
        return Archive(location: location, database: database, keys: keys, diskSync: diskSync)
    }

    /// The folder is already 0700; the database files get 0600 as well.
    static func secureDatabaseFiles(_ location: ArchiveLocation) {
        for suffix in ["", "-wal", "-shm"] {
            let path = location.databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    // MARK: - Archive facts

    /// Whether `keys` are the ones this archive was opened with. A recovery
    /// bundle may only ever wrap those (A-09).
    public func isOpened(with keys: ArchiveKeys) -> Bool {
        keysDigest.matches(keys.digest)
    }

    /// A random ID given to the archive when it was created. The recovery
    /// bundle carries it, so a bundle can only unlock its own archive (D-031).
    public func archiveID() throws -> String {
        guard let id = try meta("archive_id") else { throw ArchiveError.missingArchiveID }
        return id
    }

    public func meta(_ key: String) throws -> String? {
        try database.read { db in try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        try database.write { db in
            if let value {
                try db.execute(sql: """
                    INSERT INTO archive_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value
                    """, arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM archive_meta WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Sets several `archive_meta` rows in one transaction that is on the drive
    /// when this returns. The archive runs WAL with `synchronous = NORMAL`, where
    /// a commit reaches the disk only at the next checkpoint; for this one
    /// transaction the writer syncs the WAL with `F_FULLFSYNC` (A-04).
    public func setMetaDurably(_ values: KeyValuePairs<String, String?>) throws {
        try database.writeWithoutTransaction { db in
            try Self.durably(db) {
                try db.inTransaction {
                    for (key, value) in values {
                        if let value {
                            try db.execute(sql: """
                                INSERT INTO archive_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value
                                """, arguments: [key, value])
                        } else {
                            try db.execute(sql: "DELETE FROM archive_meta WHERE key = ?", arguments: [key])
                        }
                    }
                    return .commit
                }
            }
        }
        try diskSync.note(.durableCommit)
    }

    /// Runs `body` with every commit on this connection synced with `F_FULLFSYNC`,
    /// then puts the connection's settings back. Only outside a transaction.
    static func durably<T>(_ db: Database, _ body: () throws -> T) throws -> T {
        let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? 1
        let fullfsync = try Int.fetchOne(db, sql: "PRAGMA fullfsync") ?? 0
        try db.execute(sql: "PRAGMA synchronous = FULL")
        try db.execute(sql: "PRAGMA fullfsync = ON")
        defer {
            try? db.execute(sql: "PRAGMA synchronous = \(synchronous)")
            try? db.execute(sql: "PRAGMA fullfsync = \(fullfsync)")
        }
        return try body()
    }

    // MARK: - Accounts

    /// Adds the account if it is not there yet. Existing rows are left unchanged.
    public func register(_ account: Account) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (id, provider, email, display_name, created_at)
                    VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                    """,
                arguments: [account.id.rawValue, account.provider.rawValue, account.email, account.displayName,
                            Int(Date().timeIntervalSince1970)])
        }
    }

    public func accountExists(_ id: AccountID) throws -> Bool {
        try database.writeWithoutTransaction { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM accounts WHERE id = ?)", arguments: [id.rawValue]) ?? false
        }
    }

    // MARK: - Messages

    /// The original bytes of a stored message, rebuilt from its skeleton and
    /// attachment files when it was stored as a skeleton.
    public func rawMessage(_ id: StoredMessageID) throws -> Data? {
        let row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT raw_hash, raw_state FROM messages WHERE id = ?", arguments: [id])
        }
        guard let row else { return nil }
        return try rawMessage(hash: row["raw_hash"], state: row["raw_state"])
    }

    func rawMessage(hash: Data, state: String) throws -> Data {
        let stored = try rawFiles.read(hash)
        guard state == "skeleton" else { return stored }
        return try RawCompaction.expand(stored, attachments: attachmentFiles)
    }

    /// The header block of a stored message, without touching its attachments.
    public func headerBlock(_ id: StoredMessageID) throws -> Data? {
        let row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT raw_hash, raw_state FROM messages WHERE id = ?", arguments: [id])
        }
        guard let row else { return nil }
        let stored = try rawFiles.read(row["raw_hash"])
        if row["raw_state"] as String == "skeleton" { return try RawCompaction.headerBlock(ofSkeleton: stored) }
        return RawCompaction.headerBlock(of: stored)
    }
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case missingArchiveID
    case unknownAccount(String)

    public var description: String {
        switch self {
        case .missingArchiveID: "The archive has no archive ID; it was not opened for writing yet"
        case .unknownAccount: "No account in the archive matches that. See `stowmail account list`."
        }
    }
}
