import Foundation
import Logging
import StowCore
import StowSecrets

/// Hands out a working access token for an account, refreshing ahead of expiry.
///
/// Rules (D-110):
/// - Refresh when the token has less than five minutes left.
/// - On `invalid_grant`, mark the account as needing sign-in and stop. Never retry.
/// - An account already marked is refused at once, without touching the network.
public actor TokenProvider {
    let tokenStore: TokenStore
    let registry: any AccountDirectory
    let clientFor: @Sendable (Provider) throws -> OAuthClient
    let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.getstow.sync.tokens")

    public init(
        tokenStore: TokenStore,
        registry: any AccountDirectory,
        clientFor: @escaping @Sendable (Provider) throws -> OAuthClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenStore = tokenStore
        self.registry = registry
        self.clientFor = clientFor
        self.now = now
    }

    /// A valid access token. `forceRefresh` asks for a new one even if the
    /// current one looks fresh, for when the server has just rejected it.
    public func accessToken(for accountID: AccountID, forceRefresh: Bool = false) async throws -> String {
        guard let record = try registry.record(accountID) else {
            throw AccountDirectoryError.notFound(accountID.rawValue)
        }
        guard !record.needsSignIn else { throw SyncError.needsSignIn(accountID) }
        guard let tokens = try tokenStore.tokens(for: accountID) else {
            try registry.setNeedsSignIn(accountID, true)
            throw SyncError.needsSignIn(accountID)
        }
        guard forceRefresh || tokens.needsRefresh(at: now()) else { return tokens.accessToken }

        logger.info("Refreshing access token", metadata: ["account": "\(accountID)"])
        do {
            let refreshed = try await clientFor(record.account.provider).refresh(tokens)
            try tokenStore.save(refreshed, for: accountID)
            return refreshed.accessToken
        } catch OAuthError.invalidGrant, OAuthError.noRefreshToken {
            logger.warning("Refresh token rejected; account needs sign-in", metadata: ["account": "\(accountID)"])
            try registry.setNeedsSignIn(accountID, true)
            throw SyncError.needsSignIn(accountID)
        }
    }
}
