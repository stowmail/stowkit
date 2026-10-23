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

    public init(location: ArchiveLocation, database: DatabasePool, keys: ArchiveKeys) {
        self.location = location
        self.database = database
        rawFiles = EncryptedFileStore(directory: location.rawDirectory, kind: .raw, keys: keys)
        attachmentFiles = EncryptedFileStore(directory: location.attachmentsDirectory, kind: .attachment, keys: keys)
    }

    public static func open(_ location: ArchiveLocation, keys: ArchiveKeys, readOnly: Bool = false) throws -> Archive {
        if !readOnly { try location.prepare() }
        let database = try EncryptedDatabase.open(at: location.databaseURL, key: keys.databaseKeyData, readOnly: readOnly)
        if !readOnly {
            try ArchiveSchema.migrate(database)
            secureDatabaseFiles(location)
        }
        return Archive(location: location, database: database, keys: keys)
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
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM accounts WHERE id = ?)", arguments: [id.rawValue]) ?? false
        }
    }

    /// The decrypted original bytes of a stored message (expanded first if it was compacted).
    public func rawMessage(_ id: StoredMessageID) throws -> Data? {
        let row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT raw_hash, raw_state FROM messages WHERE id = ?", arguments: [id])
        }
        guard let row else { return nil }
        let hash: Data = row["raw_hash"]
        let stored = try rawFiles.read(hash)
        if row["raw_state"] as String == "skeleton" {
            return try RawCompaction.expand(stored, attachments: attachmentFiles)
        }
        return stored
    }
}
