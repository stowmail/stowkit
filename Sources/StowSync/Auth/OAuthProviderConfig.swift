import Foundation
import StowCore
import StowSecrets

/// Everything needed to sign in to one provider: endpoints, the app's client
/// identity, scopes and how the loopback redirect address is written.
public struct OAuthProviderConfig: Sendable, Equatable {
    public let provider: Provider
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let clientID: String
    /// Google issues a client "secret" even to desktop apps. It is not
    /// confidential, but it is still kept out of git and logs (D-007).
    public let clientSecret: String?
    public let scopes: [String]
    /// Host written in the redirect URI. The listener itself always binds
    /// 127.0.0.1 (D-102); this only has to match the app registration.
    public let redirectHost: String
    /// Extra query parameters on the authorisation URL.
    public let extraAuthorizationParameters: [(String, String)]

    public init(
        provider: Provider,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        clientSecret: String?,
        scopes: [String],
        redirectHost: String,
        extraAuthorizationParameters: [(String, String)] = []
    ) {
        self.provider = provider
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.redirectHost = redirectHost
        self.extraAuthorizationParameters = extraAuthorizationParameters
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider == rhs.provider && lhs.authorizationEndpoint == rhs.authorizationEndpoint
            && lhs.tokenEndpoint == rhs.tokenEndpoint && lhs.clientID == rhs.clientID
            && lhs.clientSecret == rhs.clientSecret && lhs.scopes == rhs.scopes && lhs.redirectHost == rhs.redirectHost
            && lhs.extraAuthorizationParameters.map(\.0) == rhs.extraAuthorizationParameters.map(\.0)
            && lhs.extraAuthorizationParameters.map(\.1) == rhs.extraAuthorizationParameters.map(\.1)
    }

    /// The redirect URI for a listener on `port`.
    public func redirectURI(port: UInt16) -> String {
        "http://\(redirectHost):\(port)/"
    }

    /// Google: full IMAP access needs `https://mail.google.com/`. `openid email`
    /// are added so the token response says which address signed in, which
    /// XOAUTH2 needs (D-103). `access_type=offline` asks for a refresh token and
    /// `prompt=consent` makes Google send one again on a repeat sign-in.
    public static func google(_ config: AppConfig) -> OAuthProviderConfig {
        OAuthProviderConfig(
            provider: .gmail,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            clientID: config.googleClientID,
            clientSecret: config.googleClientSecret,
            scopes: ["https://mail.google.com/", "openid", "email"],
            redirectHost: "127.0.0.1",
            extraAuthorizationParameters: [("access_type", "offline"), ("prompt", "consent")]
        )
    }

    /// Microsoft identity platform v2. The app registration's public client
    /// redirect is `http://localhost`, so the redirect host is `localhost` (D-102).
    public static func microsoft(_ config: AppConfig) -> OAuthProviderConfig {
        let tenant = config.microsoftTenant
        let base = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0"
        return OAuthProviderConfig(
            provider: .microsoft,
            authorizationEndpoint: URL(string: "\(base)/authorize")!,
            tokenEndpoint: URL(string: "\(base)/token")!,
            clientID: config.microsoftClientID,
            clientSecret: nil,
            scopes: ["https://outlook.office.com/IMAP.AccessAsUser.All", "offline_access", "openid", "email"],
            redirectHost: "localhost",
            extraAuthorizationParameters: [("prompt", "select_account")]
        )
    }

    /// Takes an `OAuthProvider`, not a `Provider`: iCloud has no OAuth (D-467),
    /// so there is nothing to ask for. Use `Provider.oauth` to get one.
    public static func forProvider(_ provider: OAuthProvider, config: AppConfig) -> OAuthProviderConfig {
        switch provider {
        case .gmail: google(config)
        case .microsoft: microsoft(config)
        }
    }

    /// The browser URL that starts sign-in.
    public func authorizationURL(redirectURI: String, state: String, pkce: PKCE, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ]
        items += extraAuthorizationParameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }
}
