import Foundation
import Logging
import StowCore

/// Opens an IMAP session and signs in to it with the account's credential.
///
/// OAuth: if the server refuses the token, the token is refreshed once and
/// sign-in tried once more on a new connection. A second refusal is final (D-110).
/// iCloud: one try with the app-specific password; a refusal marks the
/// account and is final at once (D-467 item 5).
public struct SessionFactory: Sendable {
    public let account: Account
    public let endpoint: IMAPEndpoint
    public let timeouts: IMAPTimeouts
    let tokens: TokenProvider
    private let logger = Logger(label: "ee.getstow.sync.session")

    public init(account: Account, endpoint: IMAPEndpoint, tokens: TokenProvider, timeouts: IMAPTimeouts = .default) {
        self.account = account
        self.endpoint = endpoint
        self.tokens = tokens
        self.timeouts = timeouts
    }

    /// The IMAP username for an account. Stow keeps the address the user
    /// typed and derives the username from it. For iCloud, Apple's help says
    /// usually the part before `@icloud.com`, sometimes the full address; the
    /// full address until measured (iCloud brief step 5).
    public static func username(for account: Account) -> String {
        switch account.provider {
        case .gmail, .microsoft, .icloud: account.email
        }
    }

    public func open() async throws -> IMAPSession {
        switch try await tokens.credential(for: account.id) {
        case .password(let password):
            do {
                return try await connectAndAuthenticate { try await $0.authenticate(user: Self.username(for: account), password: password) }
            } catch SyncError.authenticationFailed(let text) {
                // The server's own words, scrubbed (D-014): they name no password.
                logger.notice("iCloud refused the app-specific password", metadata: ["account": "\(account.id)", "reply": "\(text)"])
                try await tokens.passwordRefused(account.id)
                throw SyncError.passwordRefused(account.id)
            }
        case .accessToken(let token):
            do {
                return try await connectAndAuthenticate { try await $0.authenticate(user: account.email, accessToken: token) }
            } catch SyncError.authenticationFailed {
                logger.notice("Server refused the access token; refreshing once", metadata: ["account": "\(account.id)"])
                let fresh = try await tokens.accessToken(for: account.id, forceRefresh: true)
                return try await connectAndAuthenticate { try await $0.authenticate(user: account.email, accessToken: fresh) }
            }
        }
    }

    private func connectAndAuthenticate(_ signIn: (IMAPSession) async throws -> Void) async throws -> IMAPSession {
        let session = try await IMAPSession.connect(to: endpoint, timeouts: timeouts)
        do {
            try await signIn(session)
            if account.provider == .icloud { await session.acceptReadWriteExamineLabel() }
            return session
        } catch {
            await session.disconnect()
            throw error
        }
    }
}
