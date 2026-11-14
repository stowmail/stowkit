import Foundation
import StowCore
import StowSecrets
import Testing
@testable import StowSync

/// Answers a revocation from a script, records what was sent, and can hang or fail.
final class StubRevocationEndpoint: HTTPFormPosting, @unchecked Sendable {
    enum Behaviour: Sendable {
        case answer(Int, String)
        case fail
        case hang
    }

    private let lock = NSLock()
    private var behaviour: Behaviour
    private var sent: [(url: URL, fields: [(String, String)])] = []

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    var requests: [(url: URL, fields: [(String, String)])] { lock.withLock { sent } }

    func postForm(_ url: URL, fields: [(String, String)]) async throws -> (status: Int, body: Data) {
        let current = lock.withLock {
            sent.append((url, fields))
            return behaviour
        }
        switch current {
        case .answer(let status, let body): return (status, Data(body.utf8))
        case .fail: throw URLError(.notConnectedToInternet)
        case .hang:
            try await Task.sleep(for: .seconds(60))
            return (200, Data())
        }
    }
}

/// L-3 (D-810): disconnecting a Google account asks Google to end Stow's access, and the
/// Keychain items are gone afterwards whatever Google says.
@Suite struct TokenRevocationTests {
    let keychain = makeTestKeychain()
    static let refresh = "synthetic-refresh-token-9F3K"
    static let access = "synthetic-access-token-Q7L2"

    func setUp(provider: Provider = .gmail) throws -> (Account, TokenStore, PasswordStore) {
        let account = Account(id: .generate(), provider: provider, email: "sam@example.com", displayName: "Sam")
        let tokens = TokenStore(keychain: keychain)
        let passwords = PasswordStore(keychain: keychain)
        try tokens.save(OAuthTokens(accessToken: Self.access, refreshToken: Self.refresh, expiresAt: nil), for: account.id)
        return (account, tokens, passwords)
    }

    func run(_ behaviour: StubRevocationEndpoint.Behaviour, timeLimit: TimeInterval = 10)
        async throws -> (RevocationOutcome?, StubRevocationEndpoint, TokenStore)
    {
        let (account, tokens, passwords) = try setUp()
        let endpoint = StubRevocationEndpoint(behaviour)
        let outcome = try await CredentialRemoval.discard(
            account, tokens: tokens, passwords: passwords, revoker: GoogleTokenRevoker(http: endpoint, timeLimit: timeLimit))
        #expect(try tokens.tokens(for: account.id) == nil, "the token is still in the Keychain")
        #expect(try keychain.items().isEmpty, "a Keychain item is left")
        return (outcome, endpoint, tokens)
    }

    @Test func successIsRevokedAndSendsTheRefreshTokenToGoogleOnly() async throws {
        defer { try? keychain.deleteAll() }
        let (outcome, endpoint, _) = try await run(.answer(200, ""))
        #expect(outcome == .revoked)
        let request = try #require(endpoint.requests.first)
        #expect(endpoint.requests.count == 1)
        #expect(request.url == URL(string: "https://oauth2.googleapis.com/revoke"))
        #expect(request.url.query == nil, "the token must not be in the URL")
        #expect(request.fields.count == 1 && request.fields[0].0 == "token" && request.fields[0].1 == Self.refresh)
    }

    @Test func aTokenGoogleNoLongerKnowsIsAlreadyInvalid() async throws {
        defer { try? keychain.deleteAll() }
        let (outcome, _, _) = try await run(.answer(400, #"{"error":"invalid_token","error_description":"Token expired or revoked"}"#))
        #expect(outcome == .alreadyInvalid)
        #expect(outcome?.accessEnded == true)
    }

    @Test func anotherBadRequestIsNotConfirmed() async throws {
        defer { try? keychain.deleteAll() }
        let (outcome, _, _) = try await run(.answer(400, #"{"error":"invalid_request"}"#))
        #expect(outcome == .notConfirmed)
    }

    @Test func aServerErrorIsNotConfirmed() async throws {
        defer { try? keychain.deleteAll() }
        let (outcome, _, _) = try await run(.answer(503, "Service Unavailable"))
        #expect(outcome == .notConfirmed)
    }

    @Test func noNetworkIsNotConfirmed() async throws {
        defer { try? keychain.deleteAll() }
        let (outcome, _, _) = try await run(.fail)
        #expect(outcome == .notConfirmed)
    }

    @Test func aTimeOutIsNotConfirmedAndDoesNotWait() async throws {
        defer { try? keychain.deleteAll() }
        let started = Date()
        let (outcome, _, _) = try await run(.hang, timeLimit: 0.2)
        #expect(outcome == .notConfirmed)
        #expect(Date().timeIntervalSince(started) < 5, "the disconnect waited for Google")
    }

    @Test func noRefreshTokenIsNotConfirmedWithoutARequest() async throws {
        defer { try? keychain.deleteAll() }
        let (account, tokens, passwords) = try setUp()
        try tokens.save(OAuthTokens(accessToken: Self.access, refreshToken: nil, expiresAt: nil), for: account.id)
        let endpoint = StubRevocationEndpoint(.answer(200, ""))
        let outcome = try await CredentialRemoval.discard(
            account, tokens: tokens, passwords: passwords, revoker: GoogleTokenRevoker(http: endpoint))
        #expect(outcome == .notConfirmed)
        #expect(endpoint.requests.isEmpty)
        #expect(try keychain.items().isEmpty)
    }

    @Test func otherProvidersAreNeverRevokedAndStillDeleted() async throws {
        for provider in [Provider.microsoft, .icloud, .imap] {
            defer { try? keychain.deleteAll() }
            let (account, tokens, passwords) = try setUp(provider: provider)
            let endpoint = StubRevocationEndpoint(.answer(200, ""))
            let outcome = try await CredentialRemoval.discard(
                account, tokens: tokens, passwords: passwords, revoker: GoogleTokenRevoker(http: endpoint))
            #expect(outcome == nil, "\(provider) has nothing to revoke")
            #expect(endpoint.requests.isEmpty, "\(provider) sent a request")
            #expect(try keychain.items().isEmpty)
        }
    }

    @Test func theTokenAndTheRequestBodyNeverReachALog() async throws {
        _ = CapturedLogs.installed
        defer { try? keychain.deleteAll() }
        for behaviour in [StubRevocationEndpoint.Behaviour.answer(200, ""), .answer(400, #"{"error":"invalid_token"}"#),
                          .answer(500, "boom \(Self.refresh)"), .fail] {
            _ = try await run(behaviour)
        }
        let lines = CapturedLogs.shared.all
        #expect(lines.contains { $0.contains("ee.getstow.sync.revoke") }, "the revoker logged nothing, so this proves nothing")
        for secret in [Self.refresh, Self.access, "token=", "synthetic-"] {
            #expect(lines.allSatisfy { !$0.contains(secret) }, "a log line holds \(secret)")
        }
    }
}
