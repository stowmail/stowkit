import Foundation
import StowCore

/// Per-provider connection details and limits (brief step 5, D-106).
public struct ProviderProfile: Sendable, Equatable {
    public let provider: Provider
    public let endpoint: IMAPEndpoint
    /// Most connections Stow may open to one account at once. Phase 1 uses one;
    /// the Phase 2 scheduler may use up to this many.
    public let maxConnections: Int
    /// Stow's own download cap per rolling 24 hours, or nil for none.
    public let dailyByteLimit: Int64?

    public init(provider: Provider, endpoint: IMAPEndpoint, maxConnections: Int, dailyByteLimit: Int64?) {
        self.provider = provider
        self.endpoint = endpoint
        self.maxConnections = maxConnections
        self.dailyByteLimit = dailyByteLimit
    }

    /// Gmail allows 15 connections and 2,500 MB a day; Stow stays well under both.
    public static let gmail = ProviderProfile(provider: .gmail, endpoint: .gmail, maxConnections: 3, dailyByteLimit: 2_000_000_000)

    /// Exchange Online publishes no per-mailbox IMAP cap, so Stow keeps to a
    /// small number of connections and backs off when told to (D-004).
    public static let microsoft = ProviderProfile(provider: .microsoft, endpoint: .office365, maxConnections: 2, dailyByteLimit: nil)

    /// iCloud publishes no IMAP connection or download limits. Measured on the
    /// test account (28 Oct 2026): eight connections at once all accepted, and
    /// one connection downloaded 1,500 messages in 22 s with no slow-down, so
    /// Stow keeps to two, as for Microsoft, and sets no daily cap (D-475).
    public static let icloud = ProviderProfile(provider: .icloud, endpoint: .icloud, maxConnections: 2, dailyByteLimit: nil)

    /// Any other IMAP server (D-570, brief step 4): one connection and no daily
    /// cap unless its preset says otherwise from measurement. Sync backs off on
    /// `NO`, `BAD` and dropped connections as for every provider (D-107).
    public static func forServer(_ server: ServerProfile) -> ProviderProfile {
        ProviderProfile(provider: .imap, endpoint: server.endpoint,
                        maxConnections: server.preset?.maxConnections ?? 1, dailyByteLimit: nil)
    }

    /// The profile for an account's provider. An `imap` account needs its
    /// server details; without them it throws `serverDetailsMissing`. Throws
    /// `SyncError.importOnly` for an import-only account, which has no server (D-568).
    public static func forProvider(_ provider: Provider, server: ServerProfile? = nil) throws -> ProviderProfile {
        switch provider {
        case .gmail: return gmail
        case .microsoft: return microsoft
        case .icloud: return icloud
        case .imap:
            guard let server else { throw SyncError.serverDetailsMissing }
            return forServer(server)
        case .imported: throw SyncError.importOnly
        }
    }
}
