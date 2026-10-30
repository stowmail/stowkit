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
/// - Microsoft (Exchange Online): no authserv-id, the field starting straight with
///   a result such as `spf=pass`, as Exchange Online writes it.
/// - iCloud and anything else: never a result.
/// The DMARC entry must say `pass` and its `header.from` must be the From
/// address's domain, exactly (lowercased).
public enum ProviderAuthentication {
    public static func dmarc(_ headers: MessageHeaders, provider: Provider) -> SenderDMARC {
        guard let from = headers.from.first?.domain, !from.isEmpty,
              let topmost = headers.fields.first(where: { $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame })
        else { return .none }
        let parts = withoutComments(topmost.value).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { return .none }
        let results: ArraySlice<String>
        switch provider {
        case .gmail:
            // "mx.google.com" possibly followed by a version number.
            guard first.split(separator: " ").first?.lowercased() == "mx.google.com" else { return .none }
            results = parts.dropFirst()
        case .microsoft:
            guard first.contains("=") else { return .none }
            results = parts[...]
        case .icloud:
            return .none
        }
        guard let dmarc = results.first(where: { $0.lowercased().hasPrefix("dmarc=") }) else { return .none }
        let words = dmarc.lowercased().split(whereSeparator: \.isWhitespace)
        let result = words.first.map { $0.dropFirst("dmarc=".count) }
        let headerFrom = words.first { $0.hasPrefix("header.from=") }.map { String($0.dropFirst("header.from=".count)) }
        return result == "pass" && headerFrom == from ? .pass : .fail
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
