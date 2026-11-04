import Foundation
import Logging
import StowCore

/// Opens an IMAP session and signs in to it with the account's credential.
///
/// OAuth: if the server refuses the token, the token is refreshed once and
/// sign-in tried once more on a new connection. A second refusal is final (D-110).
/// iCloud and other IMAP servers: one try with the password; a refusal marks
/// the account and is final at once (D-467 item 5, D-570).
public struct SessionFactory: Sendable {
    public let account: Account
    public let endpoint: IMAPEndpoint
    public let timeouts: IMAPTimeouts
    /// The stored IMAP username of an `imap` account (D-570); nil for the others.
    public let serverUsername: String?
    let tokens: TokenProvider
    private let logger = Logger(label: "ee.getstow.sync.session")

    public init(account: Account, endpoint: IMAPEndpoint, tokens: TokenProvider, timeouts: IMAPTimeouts = .default,
                serverUsername: String? = nil) {
        self.account = account
        self.endpoint = endpoint
        self.tokens = tokens
        self.timeouts = timeouts
        self.serverUsername = serverUsername
    }

    /// An `imap` account's factory, from its server details.
    public init(account: Account, server: ServerProfile, tokens: TokenProvider, timeouts: IMAPTimeouts = .default) {
        self.init(account: account, endpoint: server.endpoint, tokens: tokens, timeouts: timeouts, serverUsername: server.username)
    }

    /// The IMAP username for a Gmail, Microsoft or iCloud account. Stow keeps
    /// the address the user typed and derives the username from it. For
    /// iCloud, Apple's help says usually the part before `@icloud.com`,
    /// sometimes the full address; the full address until measured (iCloud
    /// brief step 5). An `imap` account's username is stored with its server
    /// details and never derived (brief step 1).
    public static func username(for account: Account) -> String {
        account.email
    }

    public func open() async throws -> IMAPSession {
        switch try await tokens.credential(for: account.id) {
        case .password(let password):
            let generic = account.provider == .imap
            if generic && serverUsername == nil { throw SyncError.serverDetailsMissing }
            let user = generic ? serverUsername ?? "" : Self.username(for: account)
            do {
                return try await connectAndAuthenticate { try await $0.authenticate(user: user, password: password, allowLogin: generic) }
            } catch SyncError.authenticationFailed(let text) {
                // The server's own words, scrubbed (D-014): they name no password.
                logger.notice("The server refused the account's password", metadata: ["account": "\(account.id)", "reply": "\(text)"])
                try await tokens.passwordRefused(account.id)
                throw generic ? SyncError.serverPasswordRefused(account.id) : SyncError.passwordRefused(account.id)
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
