import Foundation
import Logging
import StowCore

/// Opens an IMAP session and signs in to it with a current access token.
///
/// If the server refuses the token, the token is refreshed once and sign-in
/// tried once more on a new connection. A second refusal is final (D-110).
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

    public func open() async throws -> IMAPSession {
        let token = try await tokens.accessToken(for: account.id)
        do {
            return try await connectAndAuthenticate(token: token)
        } catch SyncError.authenticationFailed {
            logger.notice("Server refused the access token; refreshing once", metadata: ["account": "\(account.id)"])
            let fresh = try await tokens.accessToken(for: account.id, forceRefresh: true)
            return try await connectAndAuthenticate(token: fresh)
        }
    }

    private func connectAndAuthenticate(token: String) async throws -> IMAPSession {
        let session = try await IMAPSession.connect(to: endpoint, timeouts: timeouts)
        do {
            try await session.authenticate(user: account.email, accessToken: token)
            return session
        } catch {
            await session.disconnect()
            throw error
        }
    }
}
