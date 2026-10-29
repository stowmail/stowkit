import Foundation

/// Parses RFC 5322 address lists, as found in From, To, Cc, Reply-To and
/// similar headers, into `EmailAddress` values.
///
/// Handles display names (plain, quoted, or RFC 2047 encoded), angle
/// addresses, comments, groups (`Team: a@example.com, b@example.com;`),
/// obsolete source routes (`<@relay:a@example.com>`) and the common broken
/// forms: a missing angle bracket, unquoted names next to a bare address,
/// stray commas. Entries without an "@" are dropped and reported, so they
/// never inflate recipient counts.
public enum AddressListParser {
    public struct Result: Sendable, Equatable {
        public var addresses: [EmailAddress]
        /// True if part of the list could not be understood.
        public var hadProblem: Bool
    }

    public static func parse(_ value: String) -> Result {
        var problem = false
        let tokens = tokenise(value, problem: &problem)
        var addresses: [EmailAddress] = []
        var current: [Token] = []
        var inGroup = false

        func flush() {
            defer { current.removeAll() }
            guard !current.isEmpty else { return }
            if let address = mailbox(from: current) {
                addresses.append(address)
            } else if current.contains(where: \.isContent) {
                problem = true
            }
        }

        for token in tokens {
            switch token.kind {
            case .special(","):
                flush()
            case .special(";"):
                flush()
                inGroup = false
            case .special(":"):
                if !inGroup, !current.contains(where: \.isAngle) {
                    // Everything so far was a group name, which is not an address.
                    current.removeAll()
                    inGroup = true
                } else {
                    current.append(Token(kind: .atom(":"), spaceBefore: token.spaceBefore))
                }
            default:
                current.append(token)
            }
        }
        flush()
        return Result(addresses: addresses, hadProblem: problem)
    }

    /// Parses one or more message identifiers (`<id@host>`), as found in
    /// Message-ID, In-Reply-To and References. Angle brackets are removed.
    /// Falls back to whitespace-separated words when there are no brackets.
    public static func messageIDs(_ value: String) -> [String] {
        var ids: [String] = []
        var problem = false
        let tokens = tokenise(value, problem: &problem)
        for token in tokens {
            if case .angle(let inner) = token.kind {
                let id = inner.filter { !$0.isWhitespace }
                if !id.isEmpty { ids.append(id) }
            }
        }
        if ids.isEmpty {
            for token in tokens {
                if case .atom(let word) = token.kind, word.count > 1 { ids.append(word) }
            }
        }
        return ids
    }

    // MARK: - Tokens

    struct Token {
        enum Kind {
            case atom(String)
            case quoted(String)
            case comment(String)
            case angle(String)
            case special(Character)
        }

        var kind: Kind
        /// Whether whitespace came before this token, so adjacent tokens can be rejoined.
        var spaceBefore: Bool

        var isAngle: Bool {
            if case .angle = kind { return true }
            return false
        }

        var isContent: Bool {
            switch kind {
            case .atom, .quoted, .angle: return true
            case .comment, .special: return false
            }
        }
    }

    private static let atomStops: Set<Character> = [" ", "\t", "\r", "\n", "\r\n", "\"", "(", "<", ",", ":", ";", ">", ")"]

    static func tokenise(_ value: String, problem: inout Bool) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(value)
        var i = 0
        var space = false

        func add(_ kind: Token.Kind) {
            tokens.append(Token(kind: kind, spaceBefore: space))
            space = false
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            // Swift reads CR LF as one Character, distinct from "\r" and "\n" (A-22).
            case " ", "\t", "\r", "\n", "\r\n":
                space = true
                i += 1
            case "\"":
                var text = ""
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "\\", i + 1 < chars.count {
                        text.append(chars[i + 1])
                        i += 2
                    } else if chars[i] == "\"" {
                        closed = true
                        i += 1
                        break
                    } else {
                        text.append(chars[i])
                        i += 1
                    }
                }
                if !closed { problem = true }
                add(.quoted(text))
            case "(":
                var text = ""
                var depth = 1
                i += 1
                while i < chars.count, depth > 0 {
                    if chars[i] == "\\", i + 1 < chars.count {
                        text.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    if chars[i] == "(" { depth += 1 }
                    if chars[i] == ")" { depth -= 1 }
                    if depth > 0 { text.append(chars[i]) }
                    i += 1
                }
                if depth > 0 { problem = true }
                add(.comment(text))
                space = true
            case "<":
                var text = ""
                var inQuotes = false
                var closed = false
                i += 1
                while i < chars.count {
                    let d = chars[i]
                    if d == "\"" { inQuotes.toggle() }
                    if d == ">", !inQuotes {
                        closed = true
                        i += 1
                        break
                    }
                    text.append(d)
                    i += 1
                }
                if !closed { problem = true }
                add(.angle(text))
            case ",", ":", ";":
                add(.special(c))
                i += 1
            case ">", ")":
                problem = true
                i += 1
            default:
                // Always takes at least one character, so the loop moves on
                // whatever the stop set holds.
                var text = String(chars[i])
                i += 1
                while i < chars.count, !atomStops.contains(chars[i]) {
                    text.append(chars[i])
                    i += 1
                }
                add(.atom(text))
            }
        }
        return tokens
    }

    // MARK: - Mailboxes

    /// Builds one address from the tokens between two commas.
    static func mailbox(from tokens: [Token]) -> EmailAddress? {
        let comment = tokens.compactMap { token -> String? in
            if case .comment(let text) = token.kind { return text }
            return nil
        }.first

        if let angleIndex = tokens.firstIndex(where: \.isAngle), case .angle(let inner) = tokens[angleIndex].kind {
            let address = cleanAngle(inner)
            guard isPlausible(address) else { return nil }
            let phrase = words(tokens[..<angleIndex], quoting: false)
            let name = displayName(phrase.joined(separator: " ")) ?? comment.flatMap(displayName)
            return EmailAddress(name: name, address: address)
        }

        // No angle brackets: the word with an "@" is the address, the rest is the name.
        var all = words(tokens[...], quoting: true)
        guard let at = all.lastIndex(where: { $0.contains("@") }) else { return nil }
        let address = all.remove(at: at)
        guard isPlausible(address) else { return nil }
        let unquotedName = words(tokens[...], quoting: false).filter { !$0.contains("@") }
        let name = displayName(unquotedName.joined(separator: " ")) ?? comment.flatMap(displayName)
        return EmailAddress(name: name, address: address)
    }

    /// Rejoins atoms and quoted strings into words, merging tokens that had no
    /// whitespace between them (so `"john doe"@example.com` stays one word).
    private static func words(_ tokens: ArraySlice<Token>, quoting: Bool) -> [String] {
        var result: [String] = []
        var current = ""
        var started = false
        for token in tokens {
            let piece: String
            switch token.kind {
            case .atom(let text): piece = text
            case .quoted(let text): piece = quoting ? "\"\(text)\"" : text
            case .comment, .angle, .special:
                if started { result.append(current) }
                current = ""
                started = false
                continue
            }
            if started, token.spaceBefore {
                result.append(current)
                current = ""
            }
            current += piece
            started = true
        }
        if started { result.append(current) }
        return result.filter { !$0.isEmpty }
    }

    /// The address inside angle brackets, without whitespace, a source route or a `mailto:` prefix.
    private static func cleanAngle(_ inner: String) -> String {
        var address = inner.filter { !$0.isWhitespace }
        if address.hasPrefix("@"), let colon = address.lastIndex(of: ":") {
            address = String(address[address.index(after: colon)...])
        }
        if address.lowercased().hasPrefix("mailto:") {
            address = String(address.dropFirst("mailto:".count))
        }
        return address
    }

    private static func isPlausible(_ address: String) -> Bool {
        guard let at = address.lastIndex(of: "@") else { return false }
        guard at != address.startIndex, address.index(after: at) != address.endIndex else { return false }
        // Whitespace is allowed only inside a quoted local part ("john doe"@example.com).
        var inQuotes = false
        for c in address {
            if c == "\"" { inQuotes.toggle() }
            if c.isWhitespace, !inQuotes { return false }
        }
        return true
    }

    /// Decodes RFC 2047 words in a display name and trims it. Nil if empty.
    static func displayName(_ raw: String) -> String? {
        let decoded = EncodedWords.decode(raw).text
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
