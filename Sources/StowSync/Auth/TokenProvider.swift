import Foundation
import Logging
import StowCore
import StowSecrets

/// What an account signs in with, as `SessionFactory` needs it.
public enum SignInCredential: Sendable {
    case accessToken(String)
    /// An iCloud app-specific password (D-467). Describes itself as redacted.
    case password(AppSpecificPassword)
}

/// Hands out a working credential for an account: an access token, refreshed
/// ahead of expiry, or an iCloud account's app-specific password (D-467).
///
/// Rules (D-110):
/// - Refresh when the token has less than five minutes left.
/// - On `invalid_grant`, mark the account as needing sign-in and stop. Never retry.
/// - An account already marked is refused at once, without touching the network.
/// - A refused app-specific password marks the account the same way; it is
///   never retried, since there is nothing to refresh (D-467 item 5).
public actor TokenProvider {
    let tokenStore: TokenStore
    let passwordStore: PasswordStore
    let registry: any AccountDirectory
    let clientFor: @Sendable (OAuthProvider) throws -> OAuthClient
    let now: @Sendable () -> Date
    private let logger = Logger(label: "ee.getstow.sync.tokens")

    public init(
        tokenStore: TokenStore,
        passwordStore: PasswordStore? = nil,
        registry: any AccountDirectory,
        clientFor: @escaping @Sendable (OAuthProvider) throws -> OAuthClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenStore = tokenStore
        // The same Keychain as the tokens unless a test says otherwise (D-471).
        self.passwordStore = passwordStore ?? PasswordStore(keychain: tokenStore.keychain)
        self.registry = registry
        self.clientFor = clientFor
        self.now = now
    }

    /// The account's credential: its app-specific password for iCloud, a valid
    /// access token otherwise. `forceRefresh` applies to tokens only.
    public func credential(for accountID: AccountID, forceRefresh: Bool = false) async throws -> SignInCredential {
        guard let record = try registry.record(accountID) else {
            throw AccountDirectoryError.notFound(accountID.rawValue)
        }
        guard record.account.provider.oauth == nil else {
            return .accessToken(try await accessToken(for: accountID, forceRefresh: forceRefresh))
        }
        guard !record.needsSignIn else { throw SyncError.needsSignIn(accountID) }
        guard let password = try passwordStore.password(for: accountID) else {
            try registry.setNeedsSignIn(accountID, true)
            throw SyncError.needsSignIn(accountID)
        }
        return .password(password)
    }

    /// The server refused the account's app-specific password: mark the
    /// account so nothing tries again until the user enters a new one.
    public func passwordRefused(_ accountID: AccountID) throws {
        logger.warning("App-specific password refused; account needs sign-in", metadata: ["account": "\(accountID)"])
        try registry.setNeedsSignIn(accountID, true)
    }

    /// A valid access token. `forceRefresh` asks for a new one even if the
    /// current one looks fresh, for when the server has just rejected it.
    public func accessToken(for accountID: AccountID, forceRefresh: Bool = false) async throws -> String {
        guard let record = try registry.record(accountID) else {
            throw AccountDirectoryError.notFound(accountID.rawValue)
        }
        guard let oauth = record.account.provider.oauth else {
            throw SyncError.protocolViolation("This account signs in with an app-specific password, not a token")
        }
        guard !record.needsSignIn else { throw SyncError.needsSignIn(accountID) }
        guard let tokens = try tokenStore.tokens(for: accountID) else {
            try registry.setNeedsSignIn(accountID, true)
            throw SyncError.needsSignIn(accountID)
        }
        guard forceRefresh || tokens.needsRefresh(at: now()) else { return tokens.accessToken }

        logger.info("Refreshing access token", metadata: ["account": "\(accountID)"])
        do {
            let refreshed = try await clientFor(oauth).refresh(tokens)
            try tokenStore.save(refreshed, for: accountID)
            return refreshed.accessToken
        } catch OAuthError.invalidGrant, OAuthError.noRefreshToken {
            logger.warning("Refresh token rejected; account needs sign-in", metadata: ["account": "\(accountID)"])
            try registry.setNeedsSignIn(accountID, true)
            throw SyncError.needsSignIn(accountID)
        }
    }
}
