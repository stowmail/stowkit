import Foundation
import GRDB
import StowCore
import StowSearch
import StowSecrets
import StowStore

public enum DirectMCPArchiveError: Error, CustomStringConvertible {
    case noArchive(String)

    public var description: String {
        switch self {
        case .noArchive(let path):
            "There is no Stow archive at \(path), or its disk is not connected. Check `stowmail doctor` in Terminal."
        }
    }
}

/// The MCP server's own connection to the archive (D-081): the database only,
/// opened read-only (SQLite's read-only open flag, so no statement can write)
/// with the database key alone. Encrypted message and attachment files are
/// never opened, and the file key is never loaded.
///
/// It opens on the first tool call, not at start-up, so an MCP client can start
/// the server without waiting on a Keychain prompt, and the prompt (if any)
/// appears when the user has just asked their assistant something. A failed
/// open is tried again on the next call.
///
/// Takes no writer lock: readers never do (D-035), and WAL lets sync write
/// while it reads.
public final class DirectMCPArchive: MCPArchive {
    let location: ArchiveLocation
    let databaseKey: @Sendable () throws -> Data
    private let opened = OpenedDatabase()

    public convenience init(location: ArchiveLocation, keys: KeyManager) {
        self.init(location: location, databaseKey: { try keys.loadDatabaseKey() })
    }

    /// `databaseKey` is called only when the database is first opened.
    public init(location: ArchiveLocation, databaseKey: @escaping @Sendable () throws -> Data) {
        self.location = location
        self.databaseKey = databaseKey
    }

    func database() throws -> DatabasePool {
        try opened.get {
            guard location.exists else { throw DirectMCPArchiveError.noArchive(location.root.path) }
            return try EncryptedDatabase.open(at: location.databaseURL, key: try databaseKey(), readOnly: true)
        }
    }

    public func mcpEnabledAccounts() async throws -> [Account] {
        try await database().read { db in try ArchiveAccounts.mcpEnabledAccounts(db) }
    }

    public func search(_ query: SearchQuery) async throws -> [SearchHit] {
        try await MessageSearcher(database: database()).search(query)
    }

    public func count(_ query: SearchQuery) async throws -> Int {
        try await MessageSearcher(database: database()).count(query)
    }

    public func folders(accounts: [AccountID]) async throws -> [ArchiveFolder] {
        try await MessageSearcher(database: database()).folders(accounts: accounts)
    }

    public func thread(of message: StoredMessageID) async throws -> MessageThread? {
        try await MessageSearcher(database: database()).thread(of: message)
    }

    public func message(_ id: StoredMessageID, bodyLimit: Int) async throws -> MessageDetail? {
        try await MessageReader(database: database()).message(id, bodyLimit: bodyLimit)
    }

    public func attachmentText(message: StoredMessageID, index: Int, offset: Int, limit: Int) async throws -> AttachmentText? {
        try await MessageReader(database: database()).attachmentText(message: message, index: index, offset: offset, limit: limit)
    }
}

/// The pool, once opened. A lock rather than an actor: opening is synchronous
/// (the Keychain and SQLCipher), and two calls must not open it twice.
private final class OpenedDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var pool: DatabasePool?

    func get(_ open: () throws -> DatabasePool) throws -> DatabasePool {
        lock.lock()
        defer { lock.unlock() }
        if let pool { return pool }
        let fresh = try open()
        pool = fresh
        return fresh
    }
}
