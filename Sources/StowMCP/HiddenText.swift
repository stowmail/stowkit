import Foundation

/// Removes characters that render as nothing but that a model still reads
/// (A-17, D-515): tag characters, Hangul fillers, stray variation selectors,
/// zero-width spaces and joiners, soft hyphens and the other Unicode
/// "default ignorable" code points, plus the interlinear annotation controls.
///
/// Kept where they do visible work, so text reads as written:
/// - ZWJ or ZWNJ alone between two letters, marks or emoji (Persian, Indic,
///   emoji ZWJ sequences), and VS16 then ZWJ inside an emoji sequence;
/// - one VS15 or VS16 after an emoji, one of VS1 to VS14 after a visible
///   character, one ideographic variation selector after a Han ideograph,
///   one Mongolian free variation selector after a Mongolian letter;
/// - LRM, RLM and ALM, which right-to-left text uses on its own;
/// - the three recommended subdivision flags (England, Scotland, Wales),
///   whose tag characters follow U+1F3F4;
/// - a byte order mark at the very start, which is dropped silently.
/// Any run of these characters longer than `maximumKeptRun` (other than a
/// flag) is treated as hidden: no real text needs more in a row.
///
/// Output only: stored mail, the index and exports are unchanged.
enum HiddenText {
    static let maximumKeptRun = 2
    static let marker = "[hidden characters removed: %d]"

    /// For bodies and attachment text: each removed run becomes one visible marker.
    static func marked(_ text: String) -> String {
        clean(text) { String(format: marker, $0) }
    }

    /// For single-line fields: each removed run becomes one space.
    static func spaced(_ text: String) -> String {
        clean(text) { _ in " " }
    }

    static func clean(_ text: String, replacement: (Int) -> String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard isInvisible(scalars[index]) else {
                result.append(scalars[index])
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isInvisible(scalars[end]) { end += 1 }
            let run = scalars[index..<end]
            let previous = index > 0 ? scalars[index - 1] : nil
            let next = end < scalars.count ? scalars[end] : nil
            if index == 0, run.count == 1, run.first == "\u{FEFF}" {
                // A byte order mark: not text.
            } else if keeps(run, after: previous, before: next) {
                result.append(contentsOf: run)
            } else {
                result.append(contentsOf: replacement(run.count).unicodeScalars)
            }
            index = end
        }
        return String(result)
    }

    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isDefaultIgnorableCodePoint || (0xFFF9...0xFFFB).contains(scalar.value)
    }

    static func keeps(_ run: ArraySlice<Unicode.Scalar>, after previous: Unicode.Scalar?, before next: Unicode.Scalar?) -> Bool {
        let values = run.map(\.value)
        if let previous, previous.value == 0x1F3F4, subdivisionFlags.contains(values) { return true }
        guard values.count <= maximumKeptRun, let first = values.first else { return false }
        if values == [0xFE0F, 0x200D] { return isEmoji(previous) && isEmoji(next) }
        guard values.count == 1 else { return false }
        switch first {
        case 0x200C, 0x200D:
            return joinable(previous) && joinable(next)
        case 0xFE0E, 0xFE0F:
            return isEmoji(previous)
        case 0xFE00...0xFE0D:
            return previous.map { !isInvisible($0) && !$0.properties.isWhitespace } ?? false
        case 0xE0100...0xE01EF:
            return previous?.properties.isIdeographic ?? false
        case 0x180B...0x180D, 0x180F:
            return previous.map { (0x1820...0x18AF).contains($0.value) } ?? false
        case 0x200E, 0x200F, 0x061C:
            return true
        default:
            return false
        }
    }

    /// England, Scotland, Wales: U+1F3F4, the tag letters, then CANCEL TAG.
    static let subdivisionFlags: Set<[UInt32]> = Set(["gbeng", "gbsct", "gbwls"].map { code in
        code.unicodeScalars.map { $0.value + 0xE0000 } + [0xE007F]
    })

    static func joinable(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return !isInvisible(scalar)
        default:
            return isEmoji(scalar)
        }
    }

    static func isEmoji(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return scalar.properties.isEmoji && scalar.value > 0x7F
    }
}
