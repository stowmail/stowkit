import Foundation
import StowCore
import StowSecrets
import Testing
@testable import StowSync

/// R21: the app's browser step in another process. The login item keeps the verifier and
/// `state`; only this sign-in's reply, on its own scheme, gives a code.
@Suite struct ExternalSignInTests {
    static let google = OAuthProviderConfig.google(clientID: "123-abc.apps.googleusercontent.com", clientSecret: nil)
    static let redirect = "com.googleusercontent.apps.123-abc:/oauth2redirect"

    func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
    }

    @Test func theURLCarriesOnlyPublicValues() {
        let signIn = ExternalSignIn(config: Self.google, redirectURI: Self.redirect, loginHint: "sam@example.com")
        let items = query(signIn.url)
        #expect(signIn.callbackScheme == "com.googleusercontent.apps.123-abc")
        #expect(items["redirect_uri"] == Self.redirect)
        #expect(items["client_id"] == "123-abc.apps.googleusercontent.com")
        #expect(items["code_challenge"] == signIn.pkce.challenge)
        #expect(items["login_hint"] == "sam@example.com")
        #expect(!signIn.url.absoluteString.contains(signIn.pkce.verifier))
        #expect(!String(describing: signIn).contains(signIn.pkce.verifier))
    }

    @Test func onlyThisSignInsReplyGivesACode() throws {
        let signIn = ExternalSignIn(config: Self.google, redirectURI: Self.redirect)
        let state = try #require(query(signIn.url)["state"])
        let good = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=\(state)&code=the-code")!
        #expect(try signIn.code(from: good) == "the-code")
        #expect(throws: LoopbackError.stateMismatch) {
            try signIn.code(from: URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=other&code=x")!)
        }
        #expect(throws: LoopbackError.stateMismatch) {
            try signIn.code(from: URL(string: "msauth.ee.getstow.Stow://auth?state=\(state)&code=x")!)
        }
        #expect(throws: LoopbackError.providerError("access_denied")) {
            try signIn.code(from: URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=\(state)&error=access_denied&error_description=Sam+said+no")!)
        }
        #expect(throws: LoopbackError.missingCode) {
            try signIn.code(from: URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=\(state)")!)
        }
    }

    /// The exchange sends the verifier and the same redirect, with no secret for an iOS-type client.
    @Test func theExchangeUsesTheVerifierAndNoSecret() async throws {
        let endpoint = FakeTokenEndpoint { _ in (200, ExternalSignInTests.tokenJSON) }
        let signIn = ExternalSignIn(config: Self.google, redirectURI: Self.redirect)
        let state = try #require(query(signIn.url)["state"])
        let grant = try await signIn.finish(URL(string: "\(Self.redirect)?state=\(state)&code=c-1")!,
                                            client: OAuthClient(config: Self.google, http: endpoint))
        #expect(grant.tokens.refreshToken == "rt-1")
        let sent = try #require(await endpoint.requests.first)
        #expect(sent["code_verifier"] == signIn.pkce.verifier)
        #expect(sent["redirect_uri"] == Self.redirect)
        #expect(sent["code"] == "c-1")
        #expect(sent["client_secret"] == nil)
    }

    @Test func theExplicitBuildersMatchTheCLIs() {
        #expect(OAuthProviderConfig.google(testAppConfig) == OAuthProviderConfig.google(clientID: testAppConfig.googleClientID, clientSecret: testAppConfig.googleClientSecret))
        #expect(OAuthProviderConfig.microsoft(testAppConfig) == OAuthProviderConfig.microsoft(clientID: testAppConfig.microsoftClientID, tenant: testAppConfig.microsoftTenant))
    }

    static let tokenJSON = #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3599,"scope":"https://www.googleapis.com/auth/gmail.readonly openid email","token_type":"Bearer"}"#
}
