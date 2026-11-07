import Foundation
import GRDB
import StowCore

/// Where an `imap` account's server is, as stored in `account_servers`
/// (R-IMAP-1, D-577). Plain values: StowSync's `ServerProfile` checks them
/// again when the account is used, so a damaged row is refused there.
public struct AccountServer: Sendable, Equatable {
    public var host: String
    public var port: Int
    /// Always `tls` today (D-570).
    public var security: String
    public var username: String
    /// The preset ID, or nil for a server the user typed.
    public var preset: String?
    /// Capability names as last read after sign-in, or nil before the first.
    public var capabilities: [String]?
    public var capabilitiesAt: Date?

    public init(host: String, port: Int, security: String, username: String, preset: String?,
                capabilities: [String]? = nil, capabilitiesAt: Date? = nil) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.preset = preset
        self.capabilities = capabilities
        self.capabilitiesAt = capabilitiesAt
    }
}

/// Reading and writing `account_servers`. A row exists exactly when the
/// account's provider is `imap`; it goes with the account (ON DELETE CASCADE)
/// and stays when the account is disconnected, so reconnecting finds it.
public struct ArchiveServers: Sendable {
    public let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    public func server(for id: AccountID) throws -> AccountServer? {
        try archive.database.read { db in try Self.server(db, id) }
    }

    /// Adds an account and its server in one transaction, so neither exists without the other.
    public func add(_ record: AccountRecord, server: AccountServer) throws {
        try archive.database.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT id FROM accounts WHERE provider = ? AND lower(email) = lower(?)",
                                                  arguments: [record.account.provider.rawValue, record.account.email]) {
                throw AccountDirectoryError.alreadyExists(AccountID(rawValue: existing))
            }
            try ArchiveAccounts.insert(db, record)
            try db.execute(sql: """
                INSERT INTO account_servers (account_id, host, port, security, username, preset, capabilities, capabilities_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    record.account.id.rawValue, server.host, server.port, server.security, server.username, server.preset,
                    server.capabilities.map { $0.joined(separator: " ") },
                    server.capabilitiesAt.map { Int($0.timeIntervalSince1970) },
                ])
        }
    }

    /// Records what the server offered at the latest sign-in.
    public func setCapabilities(_ capabilities: [String], for id: AccountID, at date: Date = Date()) throws {
        try archive.database.write { db in
            try db.execute(sql: "UPDATE account_servers SET capabilities = ?, capabilities_at = ? WHERE account_id = ?",
                           arguments: [capabilities.sorted().joined(separator: " "), Int(date.timeIntervalSince1970), id.rawValue])
            guard db.changesCount == 1 else { throw AccountDirectoryError.notFound(id.rawValue) }
        }
    }

    static func server(_ db: Database, _ id: AccountID) throws -> AccountServer? {
        // No `imap` account can predate `v6`; a read-only open may not have migrated (D-605).
        guard try db.tableExists("account_servers") else { return nil }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM account_servers WHERE account_id = ?", arguments: [id.rawValue]) else {
            return nil
        }
        return AccountServer(
            host: row["host"], port: row["port"], security: row["security"], username: row["username"], preset: row["preset"],
            capabilities: (row["capabilities"] as String?).map { $0.split(separator: " ").map(String.init) },
            capabilitiesAt: (row["capabilities_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}
