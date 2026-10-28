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

    public static func forProvider(_ provider: Provider) -> ProviderProfile {
        switch provider {
        case .gmail: gmail
        case .microsoft: microsoft
        case .icloud: icloud
        }
    }
}
