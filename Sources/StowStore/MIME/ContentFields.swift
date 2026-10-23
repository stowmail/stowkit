import Foundation
import StowCore

/// A structured MIME header value such as
/// `text/plain; charset=utf-8` or `attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.txt`:
/// a leading value plus named parameters.
///
/// Parameters follow RFC 2045 (`name=value` or `name="quoted value"`) and
/// RFC 2231 (`name*=charset'lang'percent-encoded`, and long values split
/// into `name*0`, `name*1`, ... continuations, each optionally encoded).
/// Parameter names are lowercased. As a common non-standard extra, RFC 2047
/// encoded words inside plain values are decoded too (many mailers write
/// `filename="=?UTF-8?B?...?="`).
struct ContentField: Equatable {
    /// The leading value, lowercased and trimmed (for example "text/plain").
    var value: String
    var parameters: [String: String]
    /// True if a parameter could not be decoded.
    var hadProblem: Bool

    subscript(parameter name: String) -> String? { parameters[name.lowercased()] }

    static func parse(_ raw: String) -> ContentField {
        var problem = false
        let pieces = splitOnSemicolons(raw)
        let value = stripComments(pieces.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Collect plain values, and RFC 2231 sections keyed by name and index.
        var plain: [String: String] = [:]
        var sections: [String: [Int: (text: String, encoded: Bool)]] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else {
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty { problem = true }
                continue
            }
            var name = piece[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = unquote(String(piece[piece.index(after: equals)...]))
            guard !name.isEmpty else { continue }

            var encoded = false
            if name.hasSuffix("*") {
                encoded = true
                name.removeLast()
            }
            if let star = name.firstIndex(of: "*") {
                let indexText = name[name.index(after: star)...]
                guard let index = Int(indexText), index >= 0, index < 1000 else {
                    problem = true
                    continue
                }
                let base = String(name[..<star])
                sections[base, default: [:]][index] = (rawValue, encoded)
            } else if encoded {
                sections[name, default: [:]][0] = (rawValue, true)
            } else if plain[name] == nil {
                plain[name] = rawValue
            }
        }

        var parameters: [String: String] = [:]
        for (name, value) in plain {
            let decoded = EncodedWords.decode(value)
            if decoded.hadProblem { problem = true }
            parameters[name] = decoded.text
        }
        // RFC 2231 values win over plain ones of the same name.
        for (name, parts) in sections {
            var charset: String?
            var bytes: [UInt8] = []
            for index in parts.keys.sorted() {
                guard let part = parts[index] else { continue }
                var text = Substring(part.text)
                if part.encoded {
                    if index == parts.keys.min() {
                        // charset'language'value
                        let quoteParts = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if quoteParts.count == 3 {
                            charset = quoteParts[0].isEmpty ? nil : String(quoteParts[0])
                            text = quoteParts[2]
                        }
                    }
                    bytes += percentDecode(text)
                } else {
                    bytes += Array(text.utf8)
                }
            }
            let decoded = Charset.decode(bytes, charset: charset)
            if decoded.usedFallback { problem = true }
            parameters[name] = decoded.text
        }
        return ContentField(value: value, parameters: parameters, hadProblem: problem)
    }

    /// Splits on semicolons that are outside quoted strings.
    private static func splitOnSemicolons(_ raw: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for c in raw {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if c == "\\", inQuotes {
                current.append(c)
                escaped = true
                continue
            }
            if c == "\"" { inQuotes.toggle() }
            if c == ";", !inQuotes {
                pieces.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        pieces.append(current)
        return pieces
    }

    private static func unquote(_ raw: String) -> String {
        let trimmed = stripComments(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\"") else { return trimmed }
        var result = ""
        var escaped = false
        for c in trimmed.dropFirst() {
            if escaped {
                result.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                break
            } else {
                result.append(c)
            }
        }
        return result
    }

    /// Removes `(comments)` outside quoted strings.
    private static func stripComments(_ raw: String) -> String {
        guard raw.contains("(") else { return raw }
        var result = ""
        var depth = 0
        var inQuotes = false
        for c in raw {
            if c == "\"", depth == 0 { inQuotes.toggle() }
            if !inQuotes {
                if c == "(" { depth += 1; continue }
                if c == ")", depth > 0 { depth -= 1; continue }
            }
            if depth == 0 { result.append(c) }
        }
        return result
    }

    private static func percentDecode(_ text: Substring) -> [UInt8] {
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "%"), i + 2 < utf8.count,
               let high = hex(utf8[i + 1]), let low = hex(utf8[i + 2]) {
                bytes.append(high << 4 | low)
                i += 3
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        return bytes
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
