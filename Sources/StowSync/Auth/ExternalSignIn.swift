import Foundation
import StowCore

/// A sign-in whose browser step runs somewhere else (R21, D-677): the Mac app shows Google's
/// or Microsoft's page in `ASWebAuthenticationSession` and hands back the URL the provider
/// redirected to, while this side, the login item, keeps the PKCE verifier and `state` and
/// exchanges the code. Nothing but `url` and `callbackScheme` leaves this value.
///
/// The same checks as the loopback listener (`LoopbackListener.evaluate`): `state` first, in
/// constant time, then the provider's error, then the code. The CLI's loopback flow is unchanged.
public struct ExternalSignIn: Sendable, CustomStringConvertible {
    public let provider: Provider
    /// The provider's sign-in page. Public values only: the PKCE challenge, never the verifier.
    public let url: URL
    /// The redirect's scheme, for the browser session to wait for.
    public let callbackScheme: String
    let redirectURI: String
    let state: String
    let pkce: PKCE

    public init(config: OAuthProviderConfig, redirectURI: String, loginHint: String? = nil) {
        provider = config.provider
        pkce = PKCE.generate()
        state = PKCE.randomURLSafeString(byteCount: 32)
        self.redirectURI = redirectURI
        callbackScheme = URLComponents(string: redirectURI)?.scheme ?? ""
        url = config.authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce, loginHint: loginHint)
    }

    public var description: String { "ExternalSignIn(\(provider.rawValue), verifier: [redacted])" }

    /// The authorisation code in `callback`, once it is shown to be this sign-in's reply.
    /// Throws `LoopbackError.stateMismatch` for a reply to another sign-in or another scheme,
    /// `providerError` when the provider declined (`access_denied`, `admin_policy_enforced`)
    /// and `missingCode` when there is no code.
    public func code(from callback: URL) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == callbackScheme.lowercased() else { throw LoopbackError.stateMismatch }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        guard let result = LoopbackListener.evaluate(query, expectedState: state) else { throw LoopbackError.stateMismatch }
        return try result.get()
    }

    /// Checks the reply and exchanges its code, with the verifier, for tokens.
    public func finish(_ callback: URL, client: OAuthClient) async throws -> TokenGrant {
        try await client.exchange(code: try code(from: callback), redirectURI: redirectURI, pkce: pkce)
    }
}
