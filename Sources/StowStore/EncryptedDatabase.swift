import Foundation
import GRDB
import StowSecrets

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
///
/// The pool keeps the one `KeyBuffer` it is given (it opens more connections
/// later), and each connection is keyed through `sqlite3_key` from a short-lived
/// buffer that is wiped straight after, never through SQL text or a `String`
/// (D-486, D-519).
public enum EncryptedDatabase {
    /// Opens (or creates) an encrypted database in WAL mode.
    ///
    /// Throws if SQLCipher is missing, or if `key` does not match an existing file
    /// (SQLite reports "file is not a database").
    public static func open(at url: URL, key: KeyBuffer, readOnly: Bool = false) throws -> DatabasePool {
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

    /// As `open(at:key:readOnly:)`, copying `key` into a `KeyBuffer`. The caller
    /// still owns `key`; prefer passing a `KeyBuffer`.
    public static func open(at url: URL, key: Data, readOnly: Bool = false) throws -> DatabasePool {
        try open(at: url, key: KeyBuffer(key), readOnly: readOnly)
    }

    /// The raw-key form SQLCipher reads, `x'<64 hex digits>'`: 67 bytes.
    static let rawKeyLength = 3 + 64

    /// Sets the key on a fresh connection, checks SQLCipher is really in use,
    /// then reads the schema so a wrong key fails here rather than later.
    static func applyKey(_ key: KeyBuffer, to db: Database) throws {
        let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: rawKeyLength, alignment: 1)
        defer {
            memset_s(raw.baseAddress, raw.count, 0, raw.count)
            raw.deallocate()
        }
        let digits = Array("0123456789abcdef".utf8)
        raw[0] = UInt8(ascii: "x")
        raw[1] = UInt8(ascii: "'")
        key.withUnsafeBytes { bytes in
            for (index, byte) in bytes.enumerated() {
                raw[2 + index * 2] = digits[Int(byte >> 4)]
                raw[3 + index * 2] = digits[Int(byte & 0x0F)]
            }
        }
        raw[rawKeyLength - 1] = UInt8(ascii: "'")
        // `sqlite3_key` through GRDB; the Data points at `raw` without copying it.
        try db.usePassphrase(Data(bytesNoCopy: raw.baseAddress!, count: raw.count, deallocator: .none))
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
