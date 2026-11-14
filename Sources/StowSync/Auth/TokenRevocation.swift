import Foundation
import Logging
import StowCore
import StowSecrets

/// What happened when Stow asked a provider to end its own access (L-3, D-810).
public enum RevocationOutcome: Sendable, Equatable {
    /// The provider said it ended the grant.
    case revoked
    /// The provider said the token was already revoked or expired. The grant is gone either way.
    case alreadyInvalid
    /// No answer that confirms it: no network, a time-out, an error from the provider, or no
    /// token to send. The person has to remove access in their account settings.
    case notConfirmed

    /// True when the grant is known to be gone at the provider.
    public var accessEnded: Bool { self != .notConfirmed }
}

/// Asks a provider to revoke a refresh token.
public protocol TokenRevoking: Sendable {
    /// Never throws and never waits longer than its time limit, so a disconnect cannot
    /// fail or hang because the provider is out of reach.
    func revoke(refreshToken: String) async -> RevocationOutcome
}

/// Google's revocation endpoint (D-810). The token goes in the request body to this one host,
/// over TLS, and nowhere else: not in the URL, a log or an error value (D-014).
public struct GoogleTokenRevoker: TokenRevoking {
    public static let endpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    public static let defaultTimeLimit: TimeInterval = 10

    let http: HTTPFormPosting
    let timeLimit: TimeInterval
    private let logger = Logger(label: "ee.getstow.sync.revoke")

    public init(http: HTTPFormPosting = URLSessionFormPoster(), timeLimit: TimeInterval = defaultTimeLimit) {
        self.http = http
        self.timeLimit = timeLimit
    }

    public func revoke(refreshToken: String) async -> RevocationOutcome {
        let http = self.http
        let limit = timeLimit
        let answer: (status: Int, body: Data)? = await withTaskGroup(of: (status: Int, body: Data)?.self) { group in
            group.addTask { try? await http.postForm(Self.endpoint, fields: [("token", refreshToken)]) }
            group.addTask {
                try? await Task.sleep(for: .seconds(limit))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let answer else {
            logger.warning("Revocation not confirmed: no answer in time or the request failed")
            return .notConfirmed
        }
        let outcome = Self.outcome(status: answer.status, body: answer.body)
        // Only the status code: the body is the provider's text and is never logged.
        logger.info("Revocation answered", metadata: ["status": "\(answer.status)", "outcome": "\(outcome)"])
        return outcome
    }

    private struct ErrorResponse: Decodable { var error: String? }

    /// 200 is success. 400 with `invalid_token` is a token Google no longer knows or already
    /// revoked. Anything else is not a confirmation.
    static func outcome(status: Int, body: Data) -> RevocationOutcome {
        if status == 200 { return .revoked }
        if status == 400, (try? JSONDecoder().decode(ErrorResponse.self, from: body))?.error == "invalid_token" {
            return .alreadyInvalid
        }
        return .notConfirmed
    }
}

/// The one place an account's credentials are removed on disconnect, for the command line
/// and the app's login item alike (D-810).
public enum CredentialRemoval {
    /// Revokes at the provider where one can (Google only), then deletes the tokens and the
    /// password from the Keychain whatever the answer. Returns nil for a provider that has
    /// nothing to revoke.
    ///
    /// The deletes run even when the revocation was not confirmed. If one throws, that error is
    /// thrown after the other was tried. Order matters to the caller: the account is marked
    /// disconnected only after this returns (D-032).
    public static func discard(
        _ account: Account,
        tokens: TokenStore,
        passwords: PasswordStore,
        revoker: TokenRevoking = GoogleTokenRevoker()
    ) async throws -> RevocationOutcome? {
        var outcome: RevocationOutcome?
        if account.provider == .gmail {
            // A Keychain read that fails is the same as no token to send: not confirmed.
            let refresh = (try? tokens.tokens(for: account.id))?.refreshToken
            if let refresh, !refresh.isEmpty {
                outcome = await revoker.revoke(refreshToken: refresh)
            } else {
                outcome = .notConfirmed
            }
        }
        var failure: Error?
        do { try tokens.delete(for: account.id) } catch { failure = error }
        do { try passwords.delete(for: account.id) } catch { failure = failure ?? error }
        if let failure { throw failure }
        return outcome
    }
}
