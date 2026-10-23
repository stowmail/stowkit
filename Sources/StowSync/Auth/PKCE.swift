import CryptoKit
import Foundation
import Security

/// Proof Key for Code Exchange (RFC 7636), S256 method.
///
/// The app makes a random secret (the verifier), sends only its SHA-256 hash
/// (the challenge) with the browser sign-in, and later proves it started the
/// sign-in by sending the verifier with the authorisation code. Anyone who
/// intercepts the code alone cannot exchange it for tokens.
public struct PKCE: Sendable, Equatable {
    /// 43 to 128 characters from the unreserved set. Secret: never log it.
    public let verifier: String
    /// base64url(SHA-256(verifier)), sent in the authorisation URL.
    public let challenge: String
    public let method = "S256"

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// A new verifier from 32 random bytes, which gives 43 base64url characters.
    public static func generate() -> PKCE {
        PKCE(verifier: randomURLSafeString(byteCount: 32))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Random bytes from the system's secure generator, base64url encoded without padding.
    /// Also used for the OAuth `state` value.
    public static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "The system random number generator failed")
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func == (lhs: PKCE, rhs: PKCE) -> Bool { lhs.verifier == rhs.verifier }
}

extension PKCE: CustomStringConvertible {
    /// Never shows the verifier.
    public var description: String { "PKCE(S256, verifier: [redacted])" }
}
