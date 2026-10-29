import Foundation
import StowCore
import StowSecrets
import Testing
@testable import StowSync

/// A token endpoint that holds each refresh until the test lets it go, so a
/// removal can happen while the refresh is in flight.
final class GatedTokenEndpoint: HTTPFormPosting, @unchecked Sendable {
    let arrived: AsyncStream<Void>
    private let arrivedContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var requestCount = 0

    init() {
        (arrived, arrivedContinuation) = AsyncStream.makeStream()
    }

    func postForm(_ url: URL, fields: [(String, String)]) async throws -> (status: Int, body: Data) {
        lock.withLock { requestCount += 1 }
        arrivedContinuation.yield()
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return (200, Data(#"{"access_token":"refreshed-access","refresh_token":"refreshed-refresh","expires_in":3600}"#.utf8))
    }

    func open() {
        let waiting = lock.withLock {
            opened = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }
}

/// A-12: a refresh that finishes after `account remove` deleted the token
/// item must not add it back, and a disconnected account is refused.
@Suite struct RemovedAccountTokenTests {
    let keychain = makeTestKeychain()

    func setUp(expiresIn: TimeInterval, disconnected: Bool = false) throws -> (AccountRegistry, TokenStore, Account) {
        let registry = AccountRegistry(keychain: keychain)
        let tokens = TokenStore(keychain: keychain)
        let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Sam")
        try registry.add(AccountRecord(account: account, disconnectedAt: disconnected ? Date() : nil))
        try tokens.save(OAuthTokens(accessToken: "old-access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(expiresIn)), for: account.id)
        return (registry, tokens, account)
    }

    @Test func aRefreshInFlightDoesNotBringBackADeletedToken() async throws {
        defer { try? keychain.deleteAll() }
        let (registry, tokens, account) = try setUp(expiresIn: -10)
        let endpoint = GatedTokenEndpoint()
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .google(testAppConfig), http: endpoint) }

        let refresh = Task { try await provider.accessToken(for: account.id) }
        var arrivals = endpoint.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        // `account remove` deletes the token item while the refresh is in flight.
        try tokens.delete(for: account.id)
        endpoint.open()
        let outcome = await refresh.result

        #expect(try tokens.tokens(for: account.id) == nil, "the refreshed token was saved again")
        #expect(try keychain.items().allSatisfy { !$0.hasPrefix("oauth.") })
        if case .success = outcome { Issue.record("a removed account's refresh returned a token") }
        #expect(throws: SyncError.accountRemoved(account.id)) { try outcome.get() }
    }

    @Test func aRefreshThatEndsAfterTheAccountWasDisconnectedSavesNothing() async throws {
        defer { try? keychain.deleteAll() }
        let (registry, tokens, account) = try setUp(expiresIn: -10)
        let endpoint = GatedTokenEndpoint()
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .google(testAppConfig), http: endpoint) }

        let refresh = Task { try await provider.accessToken(for: account.id) }
        var arrivals = endpoint.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        // The record is disconnected but, say, the token delete has not happened yet.
        var record = try #require(try registry.record(account.id))
        record.disconnectedAt = Date()
        try registry.save(record)
        endpoint.open()
        _ = await refresh.result

        #expect(try tokens.tokens(for: account.id)?.accessToken == "old-access", "the refreshed token was saved for a disconnected account")
    }

    @Test func aDisconnectedAccountIsRefusedWithoutNetworkOrKeychain() async throws {
        defer { try? keychain.deleteAll() }
        let (registry, tokens, account) = try setUp(expiresIn: -10, disconnected: true)
        let endpoint = FakeTokenEndpoint { _ in (200, #"{"access_token":"new-access","expires_in":3600}"#) }
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .google(testAppConfig), http: endpoint) }

        await #expect(throws: SyncError.accountRemoved(account.id)) { _ = try await provider.accessToken(for: account.id) }
        await #expect(throws: SyncError.accountRemoved(account.id)) { _ = try await provider.credential(for: account.id) }
        #expect(await endpoint.requests.isEmpty)
        #expect(try tokens.tokens(for: account.id)?.accessToken == "old-access")
        #expect(try registry.record(account.id)?.needsSignIn == false)
    }

    @Test func anOrdinaryRefreshStillReplacesTheSavedTokens() async throws {
        defer { try? keychain.deleteAll() }
        let (registry, tokens, account) = try setUp(expiresIn: -10)
        let endpoint = GatedTokenEndpoint()
        endpoint.open()
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .google(testAppConfig), http: endpoint) }
        #expect(try await provider.accessToken(for: account.id) == "refreshed-access")
        let saved = try #require(try tokens.tokens(for: account.id))
        #expect(saved.accessToken == "refreshed-access")
        #expect(saved.refreshToken == "refreshed-refresh")
        #expect(try keychain.items().filter { $0.hasPrefix("oauth.") }.count == 1)
    }
}

@Suite struct KeychainUpdateOnlyTests {
    let keychain = makeTestKeychain()

    @Test func updateNeverCreatesAnItem() throws {
        defer { try? keychain.deleteAll() }
        #expect(throws: KeychainError.itemNotFound) { try keychain.update(Data("x".utf8), for: "oauth.gone") }
        #expect(try keychain.items().isEmpty)
        try keychain.set(Data("a".utf8), for: "oauth.here")
        try keychain.update(Data("b".utf8), for: "oauth.here")
        #expect(try keychain.get("oauth.here") == Data("b".utf8))
    }

    @Test func theRemovedErrorSaysHowToReconnect() {
        let id = AccountID.generate()
        #expect(SyncError.accountRemoved(id).description.contains("stowmail account add"))
        #expect(!SyncError.accountRemoved(id).isRetryable)
    }
}
