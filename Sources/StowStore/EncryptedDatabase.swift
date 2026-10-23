import Foundation
import GRDB

public enum EncryptedDatabaseError: Error, Equatable, CustomStringConvertible {
    /// The SQLite library in this process is not SQLCipher, so the database
    /// would be written unencrypted. Opening is refused.
    case sqlcipherUnavailable
    case invalidKeyLength(Int)

    public var description: String {
        switch self {
        case .sqlcipherUnavailable: "SQLCipher is not linked; refusing to open an unencrypted database"
        case .invalidKeyLength(let count): "Database key must be 32 bytes, got \(count)"
        }
    }
}

/// Opens the archive database with SQLCipher (D-003, D-011).
///
/// Foundation for Track B, which owns everything built on top (schema,
/// migrations, importer). The key is the raw 256-bit database key from
/// `KeyManager`, passed to SQLCipher as a raw key so no password-stretching
/// step is needed.
public enum EncryptedDatabase {
    /// Opens (or creates) an encrypted database in WAL mode.
    ///
    /// Throws if SQLCipher is missing, or if `key` does not match an existing file
    /// (SQLite reports "file is not a database").
    public static func open(at url: URL, key: Data, readOnly: Bool = false) throws -> DatabasePool {
        guard key.count == 32 else { throw EncryptedDatabaseError.invalidKeyLength(key.count) }
        var configuration = Configuration()
        configuration.readonly = readOnly
        // The daemon and a CLI command can write at the same time; wait rather than fail at once.
        configuration.busyMode = .timeout(30)
        configuration.prepareDatabase { db in
            try applyKey(key, to: db)
        }
        return try DatabasePool(path: url.path, configuration: configuration)
    }

    /// Sets the key on a fresh connection, checks SQLCipher is really in use,
    /// then reads the schema so a wrong key fails here rather than later.
    static func applyKey(_ key: Data, to db: Database) throws {
        let hex = key.map { String(format: "%02x", $0) }.joined()
        try db.execute(sql: "PRAGMA key = \"x'\(hex)'\"")
        guard try String.fetchOne(db, sql: "PRAGMA cipher_version") != nil else {
            throw EncryptedDatabaseError.sqlcipherUnavailable
        }
        _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
    }

    /// The SQLCipher version string, for diagnostics. Nil means plain SQLite.
    public static func cipherVersion() throws -> String? {
        let queue = try DatabaseQueue()
        return try queue.read { db in try String.fetchOne(db, sql: "PRAGMA cipher_version") }
    }
}
