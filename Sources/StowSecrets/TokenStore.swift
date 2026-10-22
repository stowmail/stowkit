import Foundation
import StowCore

/// The OAuth tokens for one account.
///
/// `description` never shows token values, so printing or logging this type
/// by accident leaks nothing.
public struct OAuthTokens: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String?
    /// When the access token stops working. Refresh shortly before this.
    public var expiresAt: Date?
    /// Space-separated scopes the provider granted.
    public var scope: String?
    public var tokenType: String

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, scope: String? = nil, tokenType: String = "Bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    /// True when the access token has expired or will within `margin` seconds.
    public func needsRefresh(at now: Date = Date(), margin: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= margin
    }

    public var description: String {
        "OAuthTokens(access: [token redacted], refresh: \(refreshToken == nil ? "none" : "[token redacted]"), expiresAt: \(expiresAt.map { "\($0)" } ?? "unknown"))"
    }

    public var debugDescription: String { description }
}

/// Per-account OAuth tokens, kept in the Keychain and nowhere else (D-007).
public struct TokenStore: Sendable {
    public let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    static func itemName(for accountID: AccountID) -> String {
        "oauth.\(accountID.rawValue)"
    }

    public func save(_ tokens: OAuthTokens, for accountID: AccountID) throws {
        let data = try JSONEncoder().encode(tokens)
        try keychain.set(data, for: Self.itemName(for: accountID))
    }

    /// The saved tokens, or nil if the account has never signed in (or was removed).
    public func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        guard let data = try keychain.get(Self.itemName(for: accountID)) else { return nil }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public func delete(for accountID: AccountID) throws {
        try keychain.delete(Self.itemName(for: accountID))
    }
}
