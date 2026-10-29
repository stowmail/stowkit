import Foundation

/// Limits on the free text of a search (A-18, D-516), so no query can make a
/// search do unbounded work: at most `maximumBytes` of UTF-8 per text field
/// (free text, `from`, `to`, `subject`), at most `maximumTerms` words in it
/// (exclusions count, `OR` and filters such as `has:` do not), and at least
/// `minimumPrefix` characters before a `*`. Past a limit the text is cut, not
/// refused; `SearchQuery.limitsApplied` says what was cut. `FTSExpression`
/// applies the same limits to every query, however it was made.
public struct SearchLimits: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Only the first `maximumTerms` words were searched.
    public static let tooManyWords = SearchLimits(rawValue: 1 << 0)
    /// Only the first `maximumBytes` bytes were searched.
    public static let tooLong = SearchLimits(rawValue: 1 << 1)
    /// A `*` after fewer than `minimumPrefix` characters was dropped.
    public static let shortPrefix = SearchLimits(rawValue: 1 << 2)

    public static let maximumTerms = 32
    public static let maximumBytes = 1_024
    public static let minimumPrefix = 2

    /// What to tell the person searching, or nil when nothing was cut.
    public var notice: String? {
        var sentences: [String] = []
        if contains(.tooLong) { sentences.append("The search was too long, so only its first part was searched.") }
        if contains(.tooManyWords) { sentences.append("Searched for the first \(Self.maximumTerms) words only.") }
        if contains(.shortPrefix) {
            sentences.append("A * needs at least \(Self.minimumPrefix) letters before it, so a shorter word was searched as a whole word.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The text within the limits, and which limits cut it.
    public static func apply(_ text: String) -> (text: String, applied: SearchLimits) {
        var applied: SearchLimits = []
        var input = text
        if input.utf8.count > maximumBytes {
            // Cut at a character boundary at or below the limit.
            var end = input.startIndex
            var bytes = 0
            for index in input.indices {
                let size = input[index].utf8.count
                if bytes + size > maximumBytes { break }
                bytes += size
                end = input.index(after: index)
            }
            input = String(input[..<end])
            applied.insert(.tooLong)
        }
        var kept: [String] = []
        var terms = 0
        for token in tokenise(input) {
            if token == "OR" { kept.append(token); continue }
            var core = Substring(token)
            if core.hasPrefix("-"), core.count > 1 { core = core.dropFirst() }
            let prefix = core.hasSuffix("*")
            if prefix { core = core.dropLast() }
            core = Substring(core.replacingOccurrences(of: "\"", with: ""))
            // A word with no letters or digits searches for nothing; keep it as it is.
            guard core.contains(where: { $0.isLetter || $0.isNumber }) else { kept.append(token); continue }
            terms += 1
            if terms > maximumTerms {
                applied.insert(.tooManyWords)
                break
            }
            if prefix, core.count < minimumPrefix {
                kept.append(String(token.dropLast()))
                applied.insert(.shortPrefix)
            } else {
                kept.append(token)
            }
        }
        return (applied.isEmpty ? text : kept.joined(separator: " "), applied)
    }

    /// Splits on whitespace outside double quotes, keeping the quotes.
    public static func tokenise(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for c in input {
            if c == "\"" { inQuotes.toggle() }
            if c.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

extension SearchQuery {
    /// Which limits cut this query's free text or its `from`, `to` and `subject` filters.
    public var limitsApplied: SearchLimits {
        [text, from, to, subject].compactMap { $0 }.reduce(into: SearchLimits()) { $0.formUnion(SearchLimits.apply($1).applied) }
    }
}
