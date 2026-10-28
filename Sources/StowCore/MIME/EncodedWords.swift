import Foundation

/// RFC 2047 "encoded words": the `=?charset?B?...?=` and `=?charset?Q?...?=`
/// pieces that let a header such as Subject carry non-ASCII text.
///
/// Decoding is deliberately lenient, as real mail breaks the rules often:
/// - encoded words are decoded wherever they appear, not only as whole words;
/// - whitespace between two adjacent encoded words is dropped (the RFC rule);
/// - adjacent encoded words in the same charset are joined as bytes before
///   decoding, so a multi-byte character split across two words still decodes;
/// - an encoded word that cannot be decoded is left exactly as written.
///
/// Decoding takes time in proportion to the input (A-02): every attempt to
/// read a word stops `maximumWordBytes` after its `=?`, and words are looked
/// for only in the first `maximumScannedBytes` (D-494).
public enum EncodedWords {
    /// RFC 2047 allows 75 bytes per word; one more is allowed for slack.
    /// A longer "word" is kept as written.
    static let maximumWordBytes = 76
    /// Encoded words after this many bytes of a value are kept as written,
    /// and the result is marked as having a problem.
    static let maximumScannedBytes = 16 << 10

    public struct Decoded: Sendable, Equatable {
        public var text: String
        /// True if any encoded word was malformed, used an unknown charset or
        /// held bytes its charset could not represent.
        public var hadProblem: Bool
    }

    private enum Segment {
        case literal(ArraySlice<UInt8>)
        case encoded(charset: String, bytes: [UInt8], original: ArraySlice<UInt8>)
    }

    /// Decodes every encoded word in `text`. Text without `=?` is returned unchanged.
    public static func decode(_ text: String) -> Decoded {
        guard text.contains("=?") else { return Decoded(text: text, hadProblem: false) }
        let bytes = Array(text.utf8)
        var problem = false
        let segments = split(bytes, problem: &problem)

        // Drop whitespace-only literals that sit between two encoded words.
        var kept: [Segment] = []
        for (index, segment) in segments.enumerated() {
            if case .literal(let run) = segment, run.allSatisfy(isWhitespace),
               index > 0, index + 1 < segments.count,
               case .encoded = segments[index - 1], case .encoded = segments[index + 1] {
                continue
            }
            kept.append(segment)
        }

        // Join neighbouring encoded words in the same charset, then decode.
        var output = ""
        var index = 0
        while index < kept.count {
            switch kept[index] {
            case .literal(let run):
                output += String(decoding: run, as: UTF8.self)
                index += 1
            case .encoded(let charset, var joined, let original):
                var originals = [original]
                var next = index + 1
                while next < kept.count, case .encoded(let other, let more, let otherOriginal) = kept[next],
                      other.lowercased() == charset.lowercased() {
                    joined += more
                    originals.append(otherOriginal)
                    next += 1
                }
                if Charset.encoding(named: charset) == nil {
                    // Unknown charset: keep the words exactly as written.
                    problem = true
                    output += originals.map { String(decoding: $0, as: UTF8.self) }.joined()
                } else {
                    let decoded = Charset.decode(joined, charset: charset)
                    if decoded.usedFallback { problem = true }
                    output += decoded.text
                }
                index = next
            }
        }
        return Decoded(text: output, hadProblem: problem)
    }

    /// Splits text into literal runs and successfully parsed encoded words.
    private static func split(_ bytes: [UInt8], problem: inout Bool) -> [Segment] {
        var segments: [Segment] = []
        var literalStart = 0
        var i = 0
        while i + 1 < bytes.count, i < maximumScannedBytes {
            guard bytes[i] == UInt8(ascii: "="), bytes[i + 1] == UInt8(ascii: "?") else {
                i += 1
                continue
            }
            if let (charset, decoded, end) = parseWord(bytes, from: i) {
                if literalStart < i { segments.append(.literal(bytes[literalStart..<i])) }
                segments.append(.encoded(charset: charset, bytes: decoded, original: bytes[i..<end]))
                i = end
                literalStart = end
            } else {
                if looksLikeWord(bytes, from: i) { problem = true }
                i += 2
            }
        }
        if i + 1 < bytes.count, containsMarker(bytes[i...]) { problem = true }
        if literalStart < bytes.count { segments.append(.literal(bytes[literalStart...])) }
        return segments
    }

    /// Parses `=?charset?X?text?=` starting at `start`. Returns the charset,
    /// decoded bytes and the index just past `?=`, or nil if it is not a valid word.
    /// Reads at most `maximumWordBytes` from `start`.
    private static func parseWord(_ bytes: [UInt8], from start: Int) -> (String, [UInt8], Int)? {
        let limit = min(bytes.count, start + maximumWordBytes)
        var i = start + 2
        let charsetStart = i
        while i < limit, bytes[i] != UInt8(ascii: "?"), !isWhitespace(bytes[i]) { i += 1 }
        guard i < limit, bytes[i] == UInt8(ascii: "?"), i > charsetStart else { return nil }
        let charset = String(decoding: bytes[charsetStart..<i], as: UTF8.self)
        i += 1
        guard i + 1 < limit, bytes[i + 1] == UInt8(ascii: "?") else { return nil }
        let mode = bytes[i] | 0x20  // lowercase
        guard mode == UInt8(ascii: "b") || mode == UInt8(ascii: "q") else { return nil }
        i += 2
        let textStart = i
        // The encoded text runs to the next "?=" and may not contain whitespace.
        while i + 1 < limit, !(bytes[i] == UInt8(ascii: "?") && bytes[i + 1] == UInt8(ascii: "=")) {
            if isWhitespace(bytes[i]) { return nil }
            i += 1
        }
        guard i + 1 < limit else { return nil }
        let text = bytes[textStart..<i]
        let end = i + 2
        let decoded = mode == UInt8(ascii: "b") ? decodeBase64(text) : decodeQ(text)
        guard let decoded else { return nil }
        return (charset, decoded, end)
    }

    /// True if the bytes at `start` look like an attempt at an encoded word,
    /// so a parse failure is worth a warning rather than being ordinary text.
    /// Reads at most `maximumWordBytes` from `start`.
    private static func looksLikeWord(_ bytes: [UInt8], from start: Int) -> Bool {
        let limit = min(bytes.count, start + maximumWordBytes)
        var questionMarks = 0
        var i = start + 2
        while i < limit, !isWhitespace(bytes[i]) {
            if bytes[i] == UInt8(ascii: "?") { questionMarks += 1 }
            i += 1
        }
        return questionMarks >= 3
    }

    private static func containsMarker(_ bytes: ArraySlice<UInt8>) -> Bool {
        zip(bytes, bytes.dropFirst()).contains { $0 == UInt8(ascii: "=") && $1 == UInt8(ascii: "?") }
    }

    static func decodeBase64(_ text: ArraySlice<UInt8>) -> [UInt8]? {
        var string = String(decoding: text, as: UTF8.self)
        let remainder = string.utf8.count % 4
        if remainder == 2 { string += "==" } else if remainder == 3 { string += "=" }
        guard let data = Data(base64Encoded: string) else { return nil }
        return Array(data)
    }

    /// The "Q" encoding: like quoted-printable, but "_" means a space.
    static func decodeQ(_ text: ArraySlice<UInt8>) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let byte = text[i]
            if byte == UInt8(ascii: "_") {
                output.append(0x20)
                i += 1
            } else if byte == UInt8(ascii: "="), let high = hexValue(text[safe: i + 1]), let low = hexValue(text[safe: i + 2]) {
                output.append(high << 4 | low)
                i += 3
            } else {
                // A stray "=" is kept as written rather than failing the whole word.
                output.append(byte)
                i += 1
            }
        }
        return output
    }

    static func hexValue(_ byte: UInt8?) -> UInt8? {
        guard let byte else { return nil }
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }
}

extension ArraySlice where Element == UInt8 {
    fileprivate subscript(safe index: Int) -> UInt8? {
        indices.contains(index) ? self[index] : nil
    }
}
