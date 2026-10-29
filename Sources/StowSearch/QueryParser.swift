import Foundation
import StowCore

/// Turns what a person types (`invoice from:acme has:attachment after:2024-01-01`)
/// into a `SearchQuery`.
///
/// Recognised filters (case-insensitive names, values may be quoted):
/// - `from:`, `to:`, `subject:`
/// - `has:attachment` and `-has:attachment`
/// - `account:<account id>` (repeatable)
/// - `after:` / `since:` (inclusive) and `before:` (exclusive), as `YYYY-MM-DD` in UTC
/// - `in:spam` (only mail marked as spam at the provider) and `in:anywhere`
///   (spam too); by default spam is left out (D-022)
/// - `in:<folder or label>`, quoted if it has spaces (`in:"Project X"`): only
///   mail currently there (D-079). `in:spam` and `in:anywhere` keep their
///   meaning even if a folder has that name.
///
/// Everything else is free text: words, `"quoted phrases"`, `prefix*`, `OR`
/// and `-excluded` words (see `FTSExpression`). Unknown `name:value` words are
/// treated as free text, so searching for "re:" or a time like "10:30" still works.
public enum QueryParser {
    public static func parse(_ input: String, limit: Int = 50) -> SearchQuery {
        var query = SearchQuery(text: "", limit: limit)
        var free: [String] = []

        for token in tokenise(input) {
            let lower = token.lowercased()
            if lower == "has:attachment" || lower == "has:attachments" {
                query.hasAttachment = true
                continue
            }
            if lower == "-has:attachment" || lower == "-has:attachments" {
                query.hasAttachment = false
                continue
            }
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let name = token[..<colon].lowercased()
                let value = unquote(String(token[token.index(after: colon)...]))
                if !value.isEmpty {
                    switch name {
                    case "from": query.from = append(query.from, value); continue
                    case "to": query.to = append(query.to, value); continue
                    case "subject": query.subject = append(query.subject, value); continue
                    case "account": query.accounts.append(AccountID(rawValue: value)); continue
                    case "in" where value.lowercased() == "spam": query.spam = .only; continue
                    case "in" where value.lowercased() == "anywhere": query.spam = .include; continue
                    case "in": query.place = .named(value); continue
                    case "after", "since":
                        if let date = day(value) { query.since = date; continue }
                    case "before":
                        if let date = day(value) { query.before = date; continue }
                    default: break
                    }
                }
            }
            free.append(token)
        }
        query.text = free.joined(separator: " ")
        return query
    }

    private static func append(_ existing: String?, _ value: String) -> String {
        existing.map { "\($0) \(value)" } ?? value
    }

    /// Splits on spaces outside double quotes, keeping the quotes.
    static func tokenise(_ input: String) -> [String] {
        SearchLimits.tokenise(input)
    }

    private static func unquote(_ value: String) -> String {
        var text = value
        if text.hasPrefix("\"") { text.removeFirst() }
        if text.hasSuffix("\"") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `YYYY-MM-DD` as midnight UTC.
    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Builds a safe FTS5 MATCH expression from free text.
///
/// Every word becomes a quoted FTS5 string, so punctuation in what someone
/// types can never be read as FTS5 syntax (which would be an error, or worse,
/// a different query). Supported on top: `"exact phrases"`, `prefix*`, `OR`
/// between two terms, and `-word` to exclude (only alongside a positive term,
/// since FTS5 cannot search for "not X" alone). `SearchLimits` caps the text
/// first (A-18): 1 KB, 32 words, two characters before a `*`.
public enum FTSExpression {
    public static func build(_ text: String, columns: [String]? = nil) -> String? {
        var positives: [String] = []
        var negatives: [String] = []
        var pendingOr = false

        for token in QueryParser.tokenise(SearchLimits.apply(text).text) {
            if token == "OR" {
                pendingOr = !positives.isEmpty
                continue
            }
            var word = token
            var negate = false
            if word.hasPrefix("-"), word.count > 1 {
                negate = true
                word.removeFirst()
            }
            var prefix = false
            if word.hasSuffix("*") {  // `inv*` or `"inv"*`
                prefix = true
                word.removeLast()
            }
            if word.hasPrefix("\""), word.hasSuffix("\""), word.count >= 2 {
                word = String(word.dropFirst().dropLast())
            } else {
                word = word.replacingOccurrences(of: "\"", with: "")
            }
            // A term with no letters or digits would tokenise to nothing.
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let term = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (prefix ? "*" : "")
            if negate {
                negatives.append(term)
            } else if pendingOr, let last = positives.popLast() {
                positives.append("(\(last) OR \(term))")
                pendingOr = false
            } else {
                positives.append(term)
            }
        }
        guard !positives.isEmpty else { return nil }
        var expression = positives.joined(separator: " AND ")
        if !negatives.isEmpty { expression = "(\(expression)) NOT (\(negatives.joined(separator: " OR ")))" }
        if let columns {
            expression = "{\(columns.joined(separator: " "))} : (\(expression))"
        }
        return expression
    }
}
