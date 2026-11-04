import Foundation
import StowCore
import StowStore
import StowSync

/// Joins an `imap` account to its stored server details (D-577), for
/// everything that opens a session or reads an account's limits. Other
/// providers have fixed servers and need no lookup.
extension ServerProfile {
    /// The stored row, checked again as at add time. A row the checks refuse
    /// (a damaged host, a security value this build does not know) is
    /// `serverDetailsMissing`: Stow never connects somewhere it would not
    /// have accepted when the account was added.
    public init(stored: AccountServer) throws {
        guard let security = ServerSecurity(rawValue: stored.security) else { throw SyncError.serverDetailsMissing }
        do {
            try self.init(host: stored.host, port: stored.port, security: security, username: stored.username, presetID: stored.preset)
        } catch {
            throw SyncError.serverDetailsMissing
        }
    }

    /// The server for an account: nil for Gmail, Microsoft and iCloud; the
    /// stored one for `imap`, or `serverDetailsMissing` if there is none.
    public static func forAccount(_ account: Account, in archive: Archive) throws -> ServerProfile? {
        guard account.provider == .imap else { return nil }
        guard let stored = try ArchiveServers(archive: archive).server(for: account.id) else { throw SyncError.serverDetailsMissing }
        return try ServerProfile(stored: stored)
    }
}

extension ProviderProfile {
    /// An account's limits and endpoint, with its stored server for `imap`.
    public static func forAccount(_ account: Account, in archive: Archive) throws -> ProviderProfile {
        try forProvider(account.provider, server: try ServerProfile.forAccount(account, in: archive))
    }
}

extension SessionFactory {
    /// Sessions for an account, to its provider's server or, for `imap`, its stored one.
    public init(account: Account, in archive: Archive, tokens: TokenProvider, timeouts: IMAPTimeouts = .default) throws {
        if let server = try ServerProfile.forAccount(account, in: archive) {
            self.init(account: account, server: server, tokens: tokens, timeouts: timeouts)
        } else {
            self.init(account: account, endpoint: try ProviderProfile.forProvider(account.provider).endpoint, tokens: tokens, timeouts: timeouts)
        }
    }
}
