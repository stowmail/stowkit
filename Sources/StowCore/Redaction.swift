import CryptoKit
import Foundation

/// Makes values safe to log (logging policy, D-014).
///
/// Rules for every module:
/// - Never log tokens, keys, passwords, message bodies or subject lines.
/// - Email addresses only at debug level, and only through `Redact.address`.
/// - Error text that came from a server or a library goes through `Redact.scrub` first.
///
/// Every function returns plain text meant for log metadata or messages.
public enum Redact {
    /// A random key made once per process. Address hashes are stable within one
    /// run (so a log can be followed) but differ between runs, and cannot be
    /// reversed by hashing a list of known addresses.
    private static let processKey: Data = {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }()

    /// "addr:" plus 8 hex characters of a keyed hash of the normalised address.
    public static func address(_ address: String) -> String {
        let normalised = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalised.utf8), using: SymmetricKey(data: processKey))
        return "addr:" + mac.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public static func address(_ address: EmailAddress) -> String {
        Self.address(address.address)
    }

    /// Tokens are never shown, not even their length.
    public static func token(_: String) -> String {
        "[token redacted]"
    }

    /// Subject lines are never shown. Only whether one exists.
    public static func subject(_ subject: String?) -> String {
        subject == nil ? "[no subject]" : "[subject redacted]"
    }

    /// Bodies are never shown. The size is kept because it helps diagnose problems.
    public static func body(_ body: Data) -> String {
        "[body redacted, \(body.count) bytes]"
    }

    public static func body(_ body: String) -> String {
        Self.body(Data(body.utf8))
    }

    /// Removes anything secret or personal from free text such as an error
    /// message: bearer tokens, OAuth parameters, JWTs, Google tokens, long
    /// base64 runs (for example an XOAUTH2 string) and email addresses.
    public static func scrub(_ text: String) -> String {
        var result = text
        for (pattern, template) in scrubRules {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: template
            )
        }
        return replaceAddresses(in: result)
    }

    /// Pattern and replacement pairs, applied in order. Tokens go first so their
    /// pieces are not mistaken for anything else.
    private static let scrubRules: [(String, String)] = [
        // "Bearer abc..." in an Authorization header
        (#"(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[token redacted]"),
        // key=value and "key": "value" forms of OAuth and credential fields
        (#"(\b(?:access_token|refresh_token|id_token|client_secret|code_verifier|code|password|passphrase|key)\s*["']?\s*[:=]\s*["']?)[^\s"'&,}]+"#, "$1[redacted]"),
        // JSON Web Tokens
        (#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"#, "[token redacted]"),
        // Google access and refresh tokens
        (#"ya29\.[A-Za-z0-9._-]+"#, "[token redacted]"),
        (#"1//[A-Za-z0-9._-]{10,}"#, "[token redacted]"),
        // Long base64 runs, for example the SASL XOAUTH2 initial response
        (#"[A-Za-z0-9+/]{40,}={0,2}"#, "[redacted]"),
    ]

    private static func replaceAddresses(in text: String) -> String {
        let pattern = #"[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += address(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
