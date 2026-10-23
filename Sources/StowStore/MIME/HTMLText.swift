import Foundation

/// Turns an HTML email body into plain text for searching, with a light tag
/// strip rather than WebKit (brief, step 5): WebKit would load a browser
/// engine per message and could fetch remote content, which an archive must
/// never do.
///
/// Drops `<script>`, `<style>`, `<head>` and comments; turns block-level tags
/// and `<br>` into line breaks; decodes common named and all numeric
/// character references; collapses runs of spaces.
public enum HTMLText {
    private static let dropContent: Set<String> = ["script", "style", "head", "title", "noscript", "template"]
    private static let blockTags: Set<String> = [
        "br", "p", "div", "tr", "li", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "hr", "section", "article", "header", "footer", "td", "th",
    ]
    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "pound": "£", "euro": "€", "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•",
        "eacute": "é", "egrave": "è", "agrave": "à", "aacute": "á", "ccedil": "ç", "uuml": "ü", "ouml": "ö",
        "auml": "ä", "szlig": "ß", "ntilde": "ñ", "zwnj": "", "zwj": "", "shy": "",
    ]

    public static func text(fromHTML html: String) -> String {
        var output = ""
        output.reserveCapacity(html.utf8.count / 2)
        let chars = Array(html.unicodeScalars)
        var i = 0
        var skipUntil: String?

        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                // Comment
                if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                    i = find("-->", in: chars, from: i + 4).map { $0 + 3 } ?? chars.count
                    continue
                }
                guard let close = findTagEnd(chars, from: i + 1) else {
                    if skipUntil == nil { output.unicodeScalars.append(c) }
                    i += 1
                    continue
                }
                let inner = String(String.UnicodeScalarView(chars[(i + 1)..<close]))
                let isClosing = inner.hasPrefix("/")
                let name = String(inner.drop(while: { $0 == "/" })
                    .prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
                i = close + 1
                if let waiting = skipUntil {
                    if isClosing, name == waiting { skipUntil = nil }
                    continue
                }
                if !isClosing, dropContent.contains(name), !inner.hasSuffix("/") {
                    skipUntil = name
                    continue
                }
                if blockTags.contains(name) { output.append("\n") } else if name == "img" || name == "td" { output.append(" ") }
                continue
            }
            if skipUntil != nil {
                i += 1
                continue
            }
            if c == "&", let (decoded, next) = entity(chars, from: i) {
                output.append(decoded)
                i = next
                continue
            }
            output.unicodeScalars.append(c)
            i += 1
        }
        return tidy(output)
    }

    private static func findTagEnd(_ chars: [Unicode.Scalar], from start: Int) -> Int? {
        var quote: Unicode.Scalar?
        var i = start
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            } else if c == "<", i == start {
                return nil
            }
            i += 1
        }
        return nil
    }

    private static func find(_ needle: String, in chars: [Unicode.Scalar], from start: Int) -> Int? {
        let n = Array(needle.unicodeScalars)
        guard n.count <= chars.count else { return nil }
        var i = start
        while i + n.count <= chars.count {
            if chars[i] == n[0], Array(chars[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }

    private static func entity(_ chars: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        var i = start + 1
        var name = ""
        while i < chars.count, i - start <= 10, chars[i] != ";" {
            name.unicodeScalars.append(chars[i])
            i += 1
        }
        guard i < chars.count, chars[i] == ";", !name.isEmpty else { return nil }
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (String(Character(scalar)), i + 1)
        }
        guard let decoded = entities[name.lowercased()] ?? entities[name] else { return nil }
        return (decoded, i + 1)
    }

    /// Collapses spaces within lines and limits blank lines to one.
    private static func tidy(_ text: String) -> String {
        var lines: [String] = []
        var blank = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\u{A0}" })
                .joined(separator: " ")
            if collapsed.isEmpty {
                blank += 1
                if blank > 1 || lines.isEmpty { continue }
            } else {
                blank = 0
            }
            lines.append(collapsed)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
