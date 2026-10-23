import CoreFoundation
import Foundation

/// Turns bytes in a named character set (as written in a MIME header, for
/// example "ISO-8859-1" or "Shift_JIS") into a Swift string.
///
/// Foundation's `String.Encoding` covers the common sets; everything else goes
/// through CoreFoundation's IANA name table, which knows most of the sets real
/// mail uses. Decoding never fails: if the declared set does not fit the bytes
/// (a frequent problem in old mail), it falls back to UTF-8, then Windows-1252,
/// then ISO-8859-1, which accepts every byte. The caller is told when a
/// fallback was needed so it can record a warning.
public enum Charset {
    /// Labels mail software commonly gets wrong, mapped to the superset that
    /// browsers (WHATWG Encoding Standard) use for them. Mail labelled
    /// "iso-8859-1" or "us-ascii" is very often really Windows-1252, and
    /// "gb2312" is usually GBK or GB18030.
    private static let aliases: [String: String] = [
        "us-ascii": "windows-1252",
        "ascii": "windows-1252",
        "ansi_x3.4-1968": "windows-1252",
        "iso-8859-1": "windows-1252",
        "iso8859-1": "windows-1252",
        "iso_8859-1": "windows-1252",
        "latin1": "windows-1252",
        "l1": "windows-1252",
        "cp1252": "windows-1252",
        "utf8": "utf-8",
        "gb2312": "gb18030",
        "gbk": "gb18030",
        "x-gbk": "gb18030",
        "cp936": "gb18030",
        "ks_c_5601-1987": "euc-kr",
        "x-sjis": "shift_jis",
        "sjis": "shift_jis",
        "windows-31j": "shift_jis",
        "cp932": "shift_jis",
    ]

    /// The `String.Encoding` for a MIME charset label, or nil if it is unknown.
    /// Labels are matched case-insensitively and an RFC 2231 language suffix
    /// (`utf-8*en`) is ignored.
    public static func encoding(named label: String) -> String.Encoding? {
        var name = label.trimmingCharacters(in: .whitespaces).lowercased()
        if let star = name.firstIndex(of: "*") { name = String(name[..<star]) }
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        guard !name.isEmpty else { return nil }
        name = aliases[name] ?? name
        switch name {
        case "utf-8": return .utf8
        case "windows-1252": return .windowsCP1252
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// The outcome of decoding: the text, and whether the declared charset had
    /// to be abandoned (unknown name, or bytes it could not represent).
    public struct Decoded: Sendable, Equatable {
        public var text: String
        public var usedFallback: Bool
    }

    /// Decodes bytes in the named charset. A nil label means "not stated",
    /// which tries UTF-8 first without counting as a fallback.
    public static func decode(_ bytes: some Collection<UInt8>, charset label: String?) -> Decoded {
        let data = Data(bytes)
        if let label {
            if let encoding = encoding(named: label), let text = String(data: data, encoding: encoding) {
                return Decoded(text: text, usedFallback: false)
            }
            return Decoded(text: bestEffort(data), usedFallback: true)
        }
        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, usedFallback: false)
        }
        return Decoded(text: bestEffort(data), usedFallback: true)
    }

    /// UTF-8, then Windows-1252, then ISO-8859-1. The last accepts any byte, so this never fails.
    static func bestEffort(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        // ISO-8859-1 maps each byte to the Unicode code point with the same number.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: data.map { Unicode.Scalar($0) })
        return String(scalars)
    }
}
