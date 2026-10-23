import Foundation
import StowCore
import StowSecrets

/// Posts a form and returns the status code and body. Abstracted so tests can
/// answer without a network.
public protocol HTTPFormPosting: Sendable {
    func postForm(_ url: URL, fields: [(String, String)]) async throws -> (status: Int, body: Data)
}

/// The real network, through an ephemeral URLSession: no cookies, no cache,
/// nothing written to disk.
public struct URLSessionFormPoster: HTTPFormPosting {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func postForm(_ url: URL, fields: [(String, String)]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormEncoding.encode(fields).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

enum FormEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return set
    }()

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

/// OAuth failures. None of these carry a token or the provider's free-text
/// description, only fixed error codes.
public enum OAuthError: Error, Equatable, CustomStringConvertible {
    /// The refresh token was revoked or has expired. The user must sign in again.
    case invalidGrant
    /// The token endpoint returned an error other than `invalid_grant`.
    case tokenEndpoint(status: Int, error: String?)
    case malformedResponse
    /// The provider did not return a refresh token, so Stow could not keep access.
    case noRefreshToken
    /// The signed-in address could not be worked out from the sign-in.
    case noEmailAddress

    public var description: String {
        switch self {
        case .invalidGrant:
            "The provider no longer accepts this account's sign-in (invalid_grant). Sign in again with `stowmail account signin`."
        case .tokenEndpoint(let status, let error):
            "The provider's token service returned HTTP \(status)\(error.map { " (\($0))" } ?? "")."
        case .malformedResponse:
            "The provider's token service returned a response Stow could not read."
        case .noRefreshToken:
            "The provider did not return a refresh token. Remove Stow's access in the account's security settings, then sign in again."
        case .noEmailAddress:
            "Could not tell which address signed in. Pass it with --email."
        }
    }
}

/// The result of exchanging an authorisation code.
public struct TokenGrant: Sendable, CustomStringConvertible {
    public let tokens: OAuthTokens
    /// The signed-in address from the ID token, if the provider sent one.
    public let email: String?

    public var description: String { "TokenGrant(\(tokens), email: \(email == nil ? "none" : "[present]"))" }
}

/// Talks to a provider's token endpoint: exchanges codes and refreshes tokens.
public struct OAuthClient: Sendable {
    public let config: OAuthProviderConfig
    let http: HTTPFormPosting
    let now: @Sendable () -> Date

    public init(config: OAuthProviderConfig, http: HTTPFormPosting = URLSessionFormPoster(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.http = http
        self.now = now
    }

    /// Exchanges the code from the browser for tokens, proving possession of the PKCE verifier.
    public func exchange(code: String, redirectURI: String, pkce: PKCE) async throws -> TokenGrant {
        var fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", config.clientID),
            ("code_verifier", pkce.verifier),
        ]
        if let secret = config.clientSecret { fields.append(("client_secret", secret)) }
        let response = try await post(fields)
        guard let refresh = response.refreshToken, !refresh.isEmpty else { throw OAuthError.noRefreshToken }
        let tokens = OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: refresh,
            expiresAt: response.expiresIn.map { now().addingTimeInterval($0) },
            scope: response.scope,
            tokenType: response.tokenType ?? "Bearer"
        )
        return TokenGrant(tokens: tokens, email: response.idToken.flatMap(Self.email(fromIDToken:)))
    }

    /// Gets a new access token. Keeps the old refresh token unless the provider sends a new one.
    /// Throws `OAuthError.invalidGrant` when the refresh token is no longer accepted.
    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.noRefreshToken }
        var fields = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", config.clientID),
        ]
        if let secret = config.clientSecret { fields.append(("client_secret", secret)) }
        if config.provider == .microsoft { fields.append(("scope", config.scopes.joined(separator: " "))) }
        let response = try await post(fields)
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: response.expiresIn.map { now().addingTimeInterval($0) },
            scope: response.scope ?? tokens.scope,
            tokenType: response.tokenType ?? tokens.tokenType
        )
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: TimeInterval?
        var scope: String?
        var tokenType: String?
        var idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
            case idToken = "id_token"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            // Some providers send expires_in as a string.
            if let number = try? container.decodeIfPresent(Double.self, forKey: .expiresIn) {
                expiresIn = number
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .expiresIn) {
                expiresIn = Double(text)
            } else {
                expiresIn = nil
            }
            scope = try container.decodeIfPresent(String.self, forKey: .scope)
            tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
            idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        }
    }

    private struct ErrorResponse: Decodable {
        var error: String?
    }

    private func post(_ fields: [(String, String)]) async throws -> TokenResponse {
        let (status, body) = try await http.postForm(config.tokenEndpoint, fields: fields)
        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: body))?.error
            if code == "invalid_grant" { throw OAuthError.invalidGrant }
            throw OAuthError.tokenEndpoint(status: status, error: code.map(Self.safeCode))
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: body)
        } catch {
            throw OAuthError.malformedResponse
        }
    }

    /// OAuth error codes are short fixed words; anything else is dropped.
    static func safeCode(_ code: String) -> String {
        String(code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(64))
    }

    /// Reads the address from an ID token's claims (D-103).
    ///
    /// The signature is not checked: the token came straight from the
    /// provider's token endpoint over TLS in reply to this app's own request,
    /// which OpenID Connect Core (section 3.1.3.7) accepts in place of a
    /// signature check. The address is only used to name the account and for
    /// XOAUTH2, where the server checks it against the access token anyway.
    static func email(fromIDToken idToken: String) -> String? {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        if let verified = claims["email_verified"] as? Bool, verified == false { return nil }
        for key in ["email", "preferred_username", "upn"] {
            if let value = claims[key] as? String, value.contains("@") {
                return value.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
