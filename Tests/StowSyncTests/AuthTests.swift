import Foundation
import Network
import StowCore
import StowSecrets
import Testing
@testable import StowSync

@Suite struct PKCETests {
    /// RFC 7636, appendix B.
    @Test func matchesTheRFCExample() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
    }

    @Test func generatedVerifiersAreLongRandomAndURLSafe() {
        let one = PKCE.generate(), two = PKCE.generate()
        #expect(one.verifier != two.verifier)
        #expect((43...128).contains(one.verifier.count))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(one.verifier.unicodeScalars.allSatisfy(allowed.contains))
        #expect(!String(describing: one).contains(one.verifier))
    }
}

@Suite struct ProviderConfigTests {
    func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func googleAuthorisationURL() {
        let config = OAuthProviderConfig.google(testAppConfig)
        let pkce = PKCE.generate()
        let url = config.authorizationURL(redirectURI: config.redirectURI(port: 51234), state: "abc", pkce: pkce)
        #expect(url.host == "accounts.google.com")
        let q = query(url)
        #expect(q["redirect_uri"] == "http://127.0.0.1:51234/")
        #expect(q["scope"] == "https://mail.google.com/ openid email")
        #expect(q["code_challenge"] == pkce.challenge)
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == "abc")
        #expect(q["response_type"] == "code")
        #expect(q["access_type"] == "offline")
        #expect(q["code_verifier"] == nil)
        #expect(!url.absoluteString.contains(pkce.verifier))
        #expect(!url.absoluteString.contains("test-secret-value"))
    }

    @Test func microsoftAuthorisationURL() {
        let config = OAuthProviderConfig.microsoft(testAppConfig)
        let url = config.authorizationURL(redirectURI: config.redirectURI(port: 50000), state: "s", pkce: .generate(), loginHint: "sam@example.com")
        #expect(url.absoluteString.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"))
        let q = query(url)
        #expect(q["redirect_uri"] == "http://127.0.0.1:50000/")
        #expect(q["scope"] == "https://outlook.office.com/IMAP.AccessAsUser.All offline_access openid email")
        #expect(q["login_hint"] == "sam@example.com")
        #expect(config.clientSecret == nil)
    }
}

@Suite struct LoopbackTests {
    @Test func requestLineParsing() {
        let request = HTTPRequestLine.parse(Data("GET /?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        #expect(request == HTTPRequestLine(method: "GET", path: "/", query: ["code": "abc", "state": "xyz"]))
        #expect(HTTPRequestLine.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil) // incomplete
    }

    @Test func callbackEvaluation() {
        #expect(LoopbackListener.evaluate(["code": "c", "state": "s"], expectedState: "s") == .success("c"))
        #expect(LoopbackListener.evaluate(["code": "c", "state": "other"], expectedState: "s") == nil)
        #expect(LoopbackListener.evaluate(["code": "c"], expectedState: "s") == nil)
        #expect(LoopbackListener.evaluate(["error": "access_denied"], expectedState: "s") == nil)
        #expect(LoopbackListener.evaluate(["state": "s"], expectedState: "s") == .failure(.missingCode))
        #expect(LoopbackListener.evaluate(["error": "access_denied", "error_description": "personal text", "state": "s"], expectedState: "s")
            == .failure(.providerError("access_denied")))
    }

    /// Sends a raw HTTP GET to 127.0.0.1 and returns the status line.
    static func get(port: UInt16, path: String) async throws -> String {
        let (data, response) = try await URLSession(configuration: .ephemeral)
            .data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        _ = data
        return "\((response as? HTTPURLResponse)?.statusCode ?? 0)"
    }

    @Test func acceptsOneCallbackWithTheRightStateThenCloses() async throws {
        let listener = try await LoopbackListener.start(expectedState: "expected", timeout: 30)
        #expect(listener.port > 0)
        #expect(try await Self.get(port: listener.port, path: "/favicon.ico") == "404")
        #expect(try await Self.get(port: listener.port, path: "/?code=the-code&state=expected") == "200")
        #expect(try await listener.waitForCode() == "the-code")
        #expect(listener.isClosed)
        #expect(listener.callbacksReceived == 1)
        // The port no longer answers.
        await #expect(throws: (any Error).self) { _ = try await Self.get(port: listener.port, path: "/?code=x&state=expected") }
    }

    @Test func rejectsTheWrongStateAndKeepsWaiting() async throws {
        let listener = try await LoopbackListener.start(expectedState: "expected", timeout: 0.5)
        #expect(try await Self.get(port: listener.port, path: "/?code=stolen&state=forged") == "400")
        #expect(!listener.isClosed)
        await #expect(throws: LoopbackError.timedOut) { _ = try await listener.waitForCode() }
        #expect(listener.isClosed)
    }

    @Test func timesOut() async throws {
        let listener = try await LoopbackListener.start(expectedState: "s", timeout: 0.2)
        await #expect(throws: LoopbackError.timedOut) { _ = try await listener.waitForCode() }
        #expect(listener.isClosed)
    }

    @Test func bindsToLoopbackOnly() async throws {
        let listener = try await LoopbackListener.start(expectedState: "s", timeout: 30)
        defer { listener.close() }
        #expect(LoopbackListener.bindHost == "127.0.0.1")
        // A non-loopback address of this Mac must not reach the listener.
        if let address = Self.nonLoopbackIPv4() {
            let reached = await Self.canConnect(host: address, port: listener.port)
            #expect(!reached)
        }
    }

    static func nonLoopbackIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !text.hasPrefix("127.") { return text }
        }
        return nil
    }

    static func canConnect(host: String, port: UInt16) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { connection.cancel(); continuation.resume(returning: true) }
                case .failed, .waiting: if once.claim() { connection.cancel(); continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if once.claim() { connection.cancel(); continuation.resume(returning: false) }
            }
        }
    }
}

@Suite struct OAuthClientTests {
    static let tokenJSON = #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3599,"scope":"https://mail.google.com/","token_type":"Bearer"}"#

    @Test func exchangeSendsVerifierAndSecretAndReadsEmail() async throws {
        let id = fakeIDToken(["email": "sam@example.com", "email_verified": true])
        let endpoint = FakeTokenEndpoint { _ in (200, #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"id_token":"\#(id)"}"#) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = OAuthClient(config: .google(testAppConfig), http: endpoint, now: { now })
        let pkce = PKCE.generate()
        let grant = try await client.exchange(code: "code-1", redirectURI: "http://127.0.0.1:1/", pkce: pkce)
        #expect(grant.tokens.accessToken == "at-1")
        #expect(grant.tokens.refreshToken == "rt-1")
        #expect(grant.tokens.expiresAt == now.addingTimeInterval(3600))
        #expect(grant.email == "sam@example.com")
        #expect(!String(describing: grant).contains("at-1"))

        let request = try #require(await endpoint.requests.first)
        #expect(request["grant_type"] == "authorization_code")
        #expect(request["code_verifier"] == pkce.verifier)
        #expect(request["client_secret"] == "test-secret-value")
        #expect(request["redirect_uri"] == "http://127.0.0.1:1/")
    }

    @Test func exchangeWithoutRefreshTokenFails() async throws {
        let endpoint = FakeTokenEndpoint { _ in (200, #"{"access_token":"at-1","expires_in":3600}"#) }
        let client = OAuthClient(config: .microsoft(testAppConfig), http: endpoint)
        await #expect(throws: OAuthError.noRefreshToken) {
            _ = try await client.exchange(code: "c", redirectURI: "http://localhost:1/", pkce: .generate())
        }
    }

    @Test func refreshKeepsTheOldRefreshTokenAndSendsScopeForMicrosoft() async throws {
        let endpoint = FakeTokenEndpoint { _ in (200, #"{"access_token":"at-2","expires_in":"3600"}"#) }
        let client = OAuthClient(config: .microsoft(testAppConfig), http: endpoint)
        let old = OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: Date())
        let new = try await client.refresh(old)
        #expect(new.accessToken == "at-2")
        #expect(new.refreshToken == "rt-1")
        let request = try #require(await endpoint.requests.first)
        #expect(request["grant_type"] == "refresh_token")
        #expect(request["scope"]?.contains("IMAP.AccessAsUser.All") == true)
        #expect(request["client_secret"] == nil)
    }

    @Test func invalidGrantIsRecognised() async throws {
        let endpoint = FakeTokenEndpoint { _ in (400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#) }
        let client = OAuthClient(config: .google(testAppConfig), http: endpoint)
        await #expect(throws: OAuthError.invalidGrant) {
            _ = try await client.refresh(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: nil))
        }
    }

    @Test func otherErrorsKeepOnlyTheCode() async throws {
        let endpoint = FakeTokenEndpoint { _ in (401, #"{"error":"invalid_client <script>","error_description":"secret detail"}"#) }
        let client = OAuthClient(config: .google(testAppConfig), http: endpoint)
        do {
            _ = try await client.refresh(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: nil))
            Issue.record("expected an error")
        } catch let error as OAuthError {
            #expect(error == .tokenEndpoint(status: 401, error: "invalid_clientscript"))
            #expect(!error.description.contains("secret detail"))
        }
    }

    @Test func emailFromIDToken() {
        #expect(OAuthClient.email(fromIDToken: fakeIDToken(["email": "a@example.com"])) == "a@example.com")
        #expect(OAuthClient.email(fromIDToken: fakeIDToken(["preferred_username": "b@example.org"])) == "b@example.org")
        #expect(OAuthClient.email(fromIDToken: fakeIDToken(["email": "c@example.com", "email_verified": false])) == nil)
        #expect(OAuthClient.email(fromIDToken: fakeIDToken(["preferred_username": "not-an-address"])) == nil)
        #expect(OAuthClient.email(fromIDToken: "garbage") == nil)
    }

    @Test func formEncoding() {
        #expect(FormEncoding.encode([("a b", "x+y/z=&")]) == "a%20b=x%2By%2Fz%3D%26")
    }
}

@Suite struct SignInFlowTests {
    /// Plays the provider and browser: reads the authorisation URL and calls the redirect.
    @Test func endToEndWithAFakeBrowser() async throws {
        let id = fakeIDToken(["email": "sam@example.com"])
        let endpoint = FakeTokenEndpoint { fields in
            fields["code"] == "browser-code" ? (200, #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"id_token":"\#(id)"}"#) : (400, #"{"error":"invalid_request"}"#)
        }
        let flow = SignInFlow(client: OAuthClient(config: .google(testAppConfig), http: endpoint), timeout: 30)
        let grant = try await flow.run { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = items.first { $0.name == "redirect_uri" }!.value!
            let state = items.first { $0.name == "state" }!.value!
            var callback = URLComponents(string: redirect.replacingOccurrences(of: "localhost", with: "127.0.0.1"))!
            callback.queryItems = [URLQueryItem(name: "code", value: "browser-code"), URLQueryItem(name: "state", value: state)]
            Task { _ = try? await URLSession(configuration: .ephemeral).data(from: callback.url!) }
        }
        #expect(grant.email == "sam@example.com")
        #expect(grant.tokens.refreshToken == "rt")
        let request = try #require(await endpoint.requests.first)
        #expect(request["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
    }

    @Test func forgedStateNeverReachesTheTokenEndpoint() async throws {
        let endpoint = FakeTokenEndpoint { _ in (200, OAuthClientTests.tokenJSON) }
        let flow = SignInFlow(client: OAuthClient(config: .google(testAppConfig), http: endpoint), timeout: 1)
        await #expect(throws: LoopbackError.timedOut) {
            _ = try await flow.run { url in
                let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }!.value!
                Task { _ = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "\(redirect)?code=x&state=forged")!) }
            }
        }
        #expect(await endpoint.requests.isEmpty)
    }

    /// The printed address shows the client ID and scopes but no secret (D-465).
    @Test func printedAddressShowsClientIDAndScopeOnly() async throws {
        struct StopBeforeBrowser: Error {}
        let notices = Notices()
        let flow = SignInFlow(client: OAuthClient(config: .google(testAppConfig), http: FakeTokenEndpoint { _ in (200, OAuthClientTests.tokenJSON) }), timeout: 30)
        await #expect(throws: StopBeforeBrowser.self) {
            _ = try await flow.run { url in
                await notices.add(SignInFlow.addressNotice(url))
                throw StopBeforeBrowser()
            }
        }
        let notice = try #require(await notices.all.first)
        let lines = notice.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "Sign-in address (opening it in your browser now):")
        #expect(notice.contains("client_id=test-client.apps.googleusercontent.com"))
        #expect(notice.contains("scope="))
        let items = try #require(URLComponents(string: lines[1])?.queryItems)
        #expect(items.first { $0.name == "scope" }?.value == "https://mail.google.com/ openid email")
        #expect(Array(items.prefix(4).map(\.name)) == ["client_id", "response_type", "redirect_uri", "scope"])
        for secret in ["code_verifier", "client_secret", "test-secret-value", "code=", "token"] {
            #expect(!notice.contains(secret))
        }

        // The verifier itself never appears, only its challenge.
        let config = OAuthProviderConfig.google(testAppConfig)
        let pkce = PKCE.generate()
        let known = SignInFlow.addressNotice(config.authorizationURL(redirectURI: config.redirectURI(port: 51234), state: "s", pkce: pkce))
        #expect(known.contains(pkce.challenge))
        #expect(!known.contains(pkce.verifier))
    }

    private actor Notices {
        var all: [String] = []
        func add(_ notice: String) { all.append(notice) }
    }
}

@Suite struct AccountAndTokenTests {
    let keychain = makeTestKeychain()

    func setUp(provider: Provider = .gmail, expiresIn: TimeInterval) throws -> (AccountRegistry, TokenStore, Account) {
        let registry = AccountRegistry(keychain: keychain)
        let tokens = TokenStore(keychain: keychain)
        let account = Account(id: .generate(), provider: provider, email: "sam@example.com", displayName: "Sam")
        try registry.add(AccountRecord(account: account))
        try tokens.save(OAuthTokens(accessToken: "old-access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(expiresIn)), for: account.id)
        return (registry, tokens, account)
    }

    @Test func registryAddFindRemove() throws {
        defer { try? keychain.deleteAll() }
        let (registry, tokens, account) = try setUp(expiresIn: 3600)
        #expect(try registry.all().map(\.account) == [account])
        #expect(try registry.find("SAM@example.com").account == account)
        #expect(try registry.find(String(account.id.rawValue.prefix(8))).account == account)
        #expect(throws: AccountRegistryError.notFound("nobody")) { try registry.find("nobody") }
        #expect(throws: AccountRegistryError.alreadyExists(account.id)) {
            try registry.add(AccountRecord(account: Account(id: .generate(), provider: .gmail, email: "Sam@Example.com", displayName: "x")))
        }
        // The same address on the other provider is a different account.
        try registry.add(AccountRecord(account: Account(id: .generate(), provider: .microsoft, email: "sam@example.com", displayName: "Work")))

        try registry.remove(account.id, tokens: tokens)
        #expect(try tokens.tokens(for: account.id) == nil)
        #expect(try registry.record(account.id) == nil)
        #expect(try keychain.items().allSatisfy { !$0.contains(account.id.rawValue) })
    }

    @Test func freshTokenIsUsedWithoutRefreshing() async throws {
        defer { try? keychain.deleteAll() }
        let (registry, tokens, account) = try setUp(expiresIn: 3600)
        let endpoint = FakeTokenEndpoint { _ in (500, "{}") }
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .google(testAppConfig), http: endpoint) }
        #expect(try await provider.accessToken(for: account.id) == "old-access")
        #expect(await endpoint.requests.isEmpty)
    }

    @Test func refreshesAheadOfExpiryAndSaves() async throws {
        defer { try? keychain.deleteAll() }
        let (registry, tokens, account) = try setUp(expiresIn: 120) // inside the five-minute margin
        let endpoint = FakeTokenEndpoint { _ in (200, #"{"access_token":"new-access","expires_in":3600}"#) }
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .google(testAppConfig), http: endpoint) }
        #expect(try await provider.accessToken(for: account.id) == "new-access")
        let saved = try #require(try tokens.tokens(for: account.id))
        #expect(saved.accessToken == "new-access")
        #expect(saved.refreshToken == "refresh")
    }

    /// QA: an expired or revoked token gives a clear error and marks the account; no retry loop.
    @Test func invalidGrantMarksTheAccountAndNeverRetries() async throws {
        defer { try? keychain.deleteAll() }
        let (registry, tokens, account) = try setUp(expiresIn: -10)
        let endpoint = FakeTokenEndpoint { _ in (400, #"{"error":"invalid_grant"}"#) }
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .google(testAppConfig), http: endpoint) }

        await #expect(throws: SyncError.needsSignIn(account.id)) { _ = try await provider.accessToken(for: account.id) }
        #expect(try registry.record(account.id)?.needsSignIn == true)
        #expect(await endpoint.requests.count == 1)

        // Later calls fail at once, without asking the provider again.
        await #expect(throws: SyncError.needsSignIn(account.id)) { _ = try await provider.accessToken(for: account.id) }
        await #expect(throws: SyncError.needsSignIn(account.id)) { _ = try await provider.accessToken(for: account.id, forceRefresh: true) }
        #expect(await endpoint.requests.count == 1)
        #expect(SyncError.needsSignIn(account.id).description.contains("stowmail account signin"))
    }
}

@Suite struct CallbackPageTests {
    /// The branded sign-in page loads nothing from anywhere and escapes what it shows.
    @Test func pageIsSelfContainedAndEscaped() {
        let html = LoopbackListener.page("<script>x</script> & \"y\"", heading: "You're <b>in</b>")
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;x&lt;/script&gt; &amp; &quot;y&quot;"))
        #expect(html.contains("You're &lt;b&gt;in&lt;/b&gt;"))
        for remote in ["http://", "https://", "src=", "<link", "@import", "url("] {
            #expect(!html.contains(remote), "page must not load \(remote)")
        }
        #expect(html.contains("class=\"word\">stow<"))
    }
}
