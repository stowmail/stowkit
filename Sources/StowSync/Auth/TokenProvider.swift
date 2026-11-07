import Foundation
import Logging
import StowCore
import StowSecrets

/// What an account signs in with, as `SessionFactory` needs it.
public enum SignInCredential: Sendable {
    case accessToken(String)
    /// An iCloud app-specific password (D-467) or another IMAP server's
    /// password (D-570). Describes itself as redacted.
    case password(MailPassword)
}

/// Hands out a working credential for an account: an access token, refreshed
/// ahead of expiry, or an iCloud account's app-specific password (D-467).
///
/// Rules (D-110):
/// - Refresh when the token has less than five minutes left.
/// - On `invalid_grant`, mark the account as needing sign-in and stop. Never retry.
/// - An account already marked is refused at once, without touching the network.
/// - A Gmail token granted before D-583, under Gmail's full-access IMAP scope, is
///   refused with its own message and marks the account once (D-583).
/// - A refused app-specific password marks the account the same way; it is
///   never retried, since there is nothing to refresh (D-467 item 5).
/// - A removed (disconnected) account is refused before anything else, and a
///   refresh saves its tokens only into an item that still exists, for an
///   account still connected, so it never brings back what `account disconnect`
///   deleted (A-12, D-513).
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
        guard record.isConnected else { throw SyncError.accountRemoved(accountID) }
        guard record.account.provider.syncs else { throw SyncError.importOnly }
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
        logger.warning("Password refused; account needs sign-in", metadata: ["account": "\(accountID)"])
        try registry.setNeedsSignIn(accountID, true)
    }

    /// Gmail refused a call because the token lacks the read permission: mark
    /// the account so nothing tries again until the user signs in (D-592).
    public func permissionMissing(_ accountID: AccountID) throws {
        logger.warning("Gmail says the token lacks the read permission; account needs sign-in", metadata: ["account": "\(accountID)"])
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
        guard record.isConnected else { throw SyncError.accountRemoved(accountID) }
        let tokens = try tokenStore.tokens(for: accountID)
        if let tokens, Self.isOldPermission(tokens, for: oauth) {
            // Signed in before D-583 under the full-access IMAP scope: the token
            // cannot reach the Gmail API's read-only calls, and refreshing keeps
            // the old grant. Marked once; nothing is sent (D-110).
            if !record.needsSignIn {
                logger.notice("Token was granted under the previous Gmail permission; account needs sign-in", metadata: ["account": "\(accountID)"])
                try registry.setNeedsSignIn(accountID, true)
            }
            throw SyncError.oldPermission(accountID)
        }
        guard !record.needsSignIn else { throw SyncError.needsSignIn(accountID) }
        guard let tokens else {
            try registry.setNeedsSignIn(accountID, true)
            throw SyncError.needsSignIn(accountID)
        }
        guard forceRefresh || tokens.needsRefresh(at: now()) else { return tokens.accessToken }

        logger.info("Refreshing access token", metadata: ["account": "\(accountID)"])
        do {
            let refreshed = try await clientFor(oauth).refresh(tokens)
            // The account may have been removed while the refresh was in flight:
            // drop the new tokens rather than save them for it.
            guard try registry.record(accountID)?.isConnected == true,
                  try tokenStore.replace(refreshed, for: accountID)
            else {
                logger.notice("Account removed during a token refresh; the new tokens were dropped", metadata: ["account": "\(accountID)"])
                throw SyncError.accountRemoved(accountID)
            }
            return refreshed.accessToken
        } catch OAuthError.tokenEndpoint(_, "admin_policy_enforced") {
            // A Workspace admin blocked Stow. Signing in again cannot help, so
            // the account is not marked (D-110, D-592).
            throw SyncError.blockedByAdmin
        } catch OAuthError.invalidGrant, OAuthError.noRefreshToken {
            logger.warning("Refresh token rejected; account needs sign-in", metadata: ["account": "\(accountID)"])
            try registry.setNeedsSignIn(accountID, true)
            throw SyncError.needsSignIn(accountID)
        }
    }

    /// A Gmail token whose recorded grant lacks `gmail.readonly`. A token with
    /// no recorded scope is not judged here: Google always sends one, and the
    /// API's own refusal catches anything this misses.
    static func isOldPermission(_ tokens: OAuthTokens, for provider: OAuthProvider) -> Bool {
        guard provider == .gmail, let scope = tokens.scope else { return false }
        return !scope.split(separator: " ").contains { $0 == OAuthProviderConfig.gmailReadOnlyScope }
    }
}
