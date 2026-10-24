import Foundation
import GRDB
import StowCore

/// The list of accounts, kept in the archive's `accounts` table from Phase 2
/// onwards (D-032). Tokens stay in the Keychain; only the account's ID,
/// provider, address, name and status live here, encrypted with the rest of
/// the archive.
///
/// Removing an account *disconnects* it: it stops syncing and its tokens are
/// deleted, but its archived mail is kept. Adding the same address again
/// reconnects the same account.
public struct ArchiveAccounts: AccountDirectory {
    public let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    public func all() throws -> [AccountRecord] {
        try archive.database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY created_at, id").compactMap(Self.record)
        }
    }

    public func record(_ id: AccountID) throws -> AccountRecord? {
        try archive.database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [id.rawValue]).flatMap(Self.record)
        }
    }

    public func add(_ record: AccountRecord) throws {
        try archive.database.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT id FROM accounts WHERE provider = ? AND lower(email) = lower(?)",
                                                  arguments: [record.account.provider.rawValue, record.account.email]) {
                throw AccountDirectoryError.alreadyExists(AccountID(rawValue: existing))
            }
            try Self.insert(db, record)
        }
    }

    public func setNeedsSignIn(_ id: AccountID, _ value: Bool) throws {
        try archive.database.write { db in
            try db.execute(sql: "UPDATE accounts SET needs_reauth = ? WHERE id = ?", arguments: [value, id.rawValue])
            guard db.changesCount == 1 else { throw AccountDirectoryError.notFound(id.rawValue) }
        }
    }

    /// The disconnected account with this provider and address, if there is one.
    public func disconnected(provider: Provider, email: String) throws -> AccountRecord? {
        try all().first {
            !$0.isConnected && $0.account.provider == provider && $0.account.email.lowercased() == email.lowercased()
        }
    }

    /// Stops an account syncing, keeping its archived mail. The caller deletes its tokens.
    public func disconnect(_ id: AccountID, at date: Date = Date()) throws {
        try archive.database.write { db in
            try db.execute(sql: "UPDATE accounts SET disconnected_at = ?, needs_reauth = 0 WHERE id = ?",
                           arguments: [Int(date.timeIntervalSince1970), id.rawValue])
            guard db.changesCount == 1 else { throw AccountDirectoryError.notFound(id.rawValue) }
        }
    }

    public func reconnect(_ id: AccountID) throws {
        try archive.database.write { db in
            try db.execute(sql: "UPDATE accounts SET disconnected_at = NULL, needs_reauth = 0 WHERE id = ?", arguments: [id.rawValue])
            guard db.changesCount == 1 else { throw AccountDirectoryError.notFound(id.rawValue) }
        }
    }

    public func rename(_ id: AccountID, to name: String) throws {
        try archive.database.write { db in
            try db.execute(sql: "UPDATE accounts SET display_name = ? WHERE id = ?", arguments: [name, id.rawValue])
        }
    }

    /// Copies Phase 1 account records (from the Keychain) into the archive,
    /// keeping their IDs so their tokens and any downloaded mail still match.
    /// Records already present are left alone. Returns the IDs now in the archive.
    @discardableResult
    public func adopt(_ records: [AccountRecord]) throws -> [AccountID] {
        try archive.database.write { db in
            var adopted: [AccountID] = []
            for record in records {
                let known = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM accounts WHERE id = ?)",
                                              arguments: [record.account.id.rawValue]) ?? false
                if !known { try Self.insert(db, record) }
                adopted.append(record.account.id)
            }
            return adopted
        }
    }

    /// The last sync's outcome for one account, for `stowmail status` (D-036).
    public func recordSync(_ id: AccountID, at date: Date, error: String?) throws {
        try archive.database.write { db in
            let at = Int(date.timeIntervalSince1970)
            if let error {
                try db.execute(sql: "UPDATE accounts SET last_sync_at = ?, last_error = ?, last_error_at = ? WHERE id = ?",
                               arguments: [at, error, at, id.rawValue])
            } else {
                try db.execute(sql: "UPDATE accounts SET last_sync_at = ?, last_success_at = ?, last_error = NULL WHERE id = ?",
                               arguments: [at, at, id.rawValue])
            }
        }
    }

    // MARK: Assistant access (MCP, D-081)

    /// Turns MCP access on or off for one account. Off by default (`accounts.mcp_enabled`).
    public func setMCPEnabled(_ id: AccountID, _ enabled: Bool) throws {
        try archive.database.write { db in
            try db.execute(sql: "UPDATE accounts SET mcp_enabled = ? WHERE id = ?", arguments: [enabled, id.rawValue])
            guard db.changesCount == 1 else { throw AccountDirectoryError.notFound(id.rawValue) }
        }
    }

    /// The accounts MCP may see.
    public func mcpEnabled() throws -> [Account] {
        try archive.database.read { db in try Self.mcpEnabledAccounts(db) }
    }

    /// The accounts MCP may see, for a reader holding only the database (the MCP server never opens an `Archive`).
    public static func mcpEnabledAccounts(_ db: Database) throws -> [Account] {
        try Row.fetchAll(db, sql: "SELECT * FROM accounts WHERE mcp_enabled = 1 ORDER BY created_at, id")
            .compactMap(record).map(\.account)
    }

    static func insert(_ db: Database, _ record: AccountRecord) throws {
        try db.execute(sql: """
            INSERT INTO accounts (id, provider, email, display_name, created_at, needs_reauth, disconnected_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                record.account.id.rawValue, record.account.provider.rawValue, record.account.email, record.account.displayName,
                Int(record.addedAt.timeIntervalSince1970), record.needsSignIn,
                record.disconnectedAt.map { Int($0.timeIntervalSince1970) },
            ])
    }

    /// Nil for a provider this build does not know (added by a newer Stow): it is left out, never guessed.
    static func record(_ row: Row) -> AccountRecord? {
        guard let provider = Provider(rawValue: row["provider"]) else { return nil }
        return AccountRecord(
            account: Account(id: AccountID(rawValue: row["id"]), provider: provider,
                             email: row["email"], displayName: row["display_name"]),
            needsSignIn: row["needs_reauth"],
            addedAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int64)),
            disconnectedAt: (row["disconnected_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
