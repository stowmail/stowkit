import Foundation
import Logging
import StowCore

/// Runs one browser sign-in: authorisation code flow with PKCE and a loopback redirect.
///
/// 1. Make a PKCE verifier and a random `state`.
/// 2. Listen on 127.0.0.1 on a free port.
/// 3. Open the browser at the provider's sign-in page (the caller supplies how).
/// 4. Wait for exactly one redirect, check `state`, close the listener.
/// 5. Exchange the code (plus the verifier) for tokens.
///
/// Nothing here stores tokens: the caller saves the grant with `TokenStore`.
public struct SignInFlow: Sendable {
    public let client: OAuthClient
    public let timeout: TimeInterval
    private let logger = Logger(label: "ee.getstow.sync.signin")

    public init(client: OAuthClient, timeout: TimeInterval = LoopbackListener.defaultTimeout) {
        self.client = client
        self.timeout = timeout
    }

    /// What `stowmail` prints before opening the browser, so the client ID and
    /// scopes stay readable after Google rewrites the address bar (D-465). The
    /// URL holds only public values: the PKCE challenge, never the verifier.
    public static func addressNotice(_ url: URL) -> String {
        "Sign-in address (opening it in your browser now):\n\(url.absoluteString)"
    }

    public func run(
        loginHint: String? = nil,
        openBrowser: @Sendable (URL) async throws -> Void
    ) async throws -> TokenGrant {
        let pkce = PKCE.generate()
        let state = PKCE.randomURLSafeString(byteCount: 32)
        let listener = try await LoopbackListener.start(expectedState: state, timeout: timeout)
        defer { listener.close() }

        let redirectURI = client.config.redirectURI(port: listener.port)
        let url = client.config.authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce, loginHint: loginHint)
        logger.info("Waiting for browser sign-in", metadata: ["provider": "\(client.config.provider.rawValue)", "port": "\(listener.port)"])
        try await openBrowser(url)

        let code = try await listener.waitForCode()
        logger.info("Received authorisation code; exchanging it for tokens")
        return try await client.exchange(code: code, redirectURI: redirectURI, pkce: pkce)
    }
}
