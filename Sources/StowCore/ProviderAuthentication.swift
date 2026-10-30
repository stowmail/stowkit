import Foundation

/// What the mail provider's own check said about the sender's domain (DMARC).
public enum SenderDMARC: String, Sendable, Codable, CaseIterable {
    /// The provider's header says DMARC passed for the From domain.
    case pass
    /// The provider's header gives another DMARC result for the From domain, or for another domain.
    case fail
    /// No usable result: no header from the provider, no DMARC entry, or a provider that adds none.
    case none
}

/// Reads the DMARC result the provider itself added to a message (D-486, D-521).
///
/// Only the topmost `Authentication-Results` field counts: the provider adds its
/// own at the top when the message arrives, and anything below it, like
/// `ARC-Authentication-Results`, may have been written by the sender. The
/// topmost field must also be in the provider's own form:
/// - Gmail: authserv-id `mx.google.com`.
/// - Microsoft (Outlook.com and Exchange Online): authserv-id `mx.microsoft.com`.
///   A field with no authserv-id is not Microsoft's: anyone can write one.
/// - iCloud and anything else: never a result.
/// The authserv-id may be followed by a version number (`mx.microsoft.com 1`).
/// The DMARC entry must say `pass` and its `header.from` must be the From
/// address's domain (lowercased) or a parent of it (D-523).
public enum ProviderAuthentication {
    public static func dmarc(_ headers: MessageHeaders, provider: Provider) -> SenderDMARC {
        guard let from = headers.from.first?.domain, !from.isEmpty,
              let topmost = headers.fields.first(where: { $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame })
        else { return .none }
        let parts = withoutComments(topmost.value).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { return .none }
        switch provider {
        case .gmail:
            guard isAuthservID(first, "mx.google.com") else { return .none }
        case .microsoft:
            guard isAuthservID(first, "mx.microsoft.com") else { return .none }
        case .icloud:
            return .none
        }
        let results = parts.dropFirst()
        guard let dmarc = results.first(where: { $0.lowercased().hasPrefix("dmarc=") }) else { return .none }
        let words = dmarc.lowercased().split(whereSeparator: \.isWhitespace)
        let result = words.first.map { $0.dropFirst("dmarc=".count) }
        let headerFrom = words.first { $0.hasPrefix("header.from=") }.map { String($0.dropFirst("header.from=".count)) }
        return result == "pass" && headerFrom.map({ isFromOrParent($0, of: from) }) == true ? .pass : .fail
    }

    /// Whether `headerFrom` is the From domain or a parent of it (D-523): Gmail
    /// names the parent domain whose DMARC policy it applied when the From address
    /// is at a subdomain (`mail.example.com` gives `header.from=example.com`).
    /// A single label is never a parent; nor is a suffix without a dot
    /// (`example.com` is not a parent of `badexample.com`).
    static func isFromOrParent(_ headerFrom: String, of from: String) -> Bool {
        headerFrom == from || (headerFrom.contains(".") && from.hasSuffix("." + headerFrom))
    }

    /// Whether `part` is exactly `id`, possibly followed by a version number (RFC 8601).
    static func isAuthservID(_ part: String, _ id: String) -> Bool {
        let words = part.split(whereSeparator: \.isWhitespace)
        guard words.first?.lowercased() == id else { return false }
        return words.count == 1 || (words.count == 2 && words[1].allSatisfy({ $0.isASCII && $0.isNumber }))
    }

    /// Removes RFC 5322 comments, `( ... )`, nested or not, which may hold any text.
    static func withoutComments(_ value: String) -> String {
        var depth = 0
        var result = ""
        for character in value {
            if character == "(" { depth += 1; continue }
            if character == ")", depth > 0 { depth -= 1; continue }
            if depth == 0 { result.append(character) }
        }
        return result
    }
}
