import StowCore
import Testing

/// A-14, A-15 (D-514): text that reaches the terminal or a log line is kept to one line.
@Suite struct OneLineTests {
    @Test func lineBreaksAndControlsAreShownEscaped() {
        #expect(Redact.oneLine("a\rb\nc\r\nd\te") == #"a\rb\nc\r\nd\te"#)
        #expect(Redact.oneLine("x\u{1B}[2Ky") == #"x\u{1B}[2Ky"#)
        #expect(Redact.oneLine("\u{0}\u{7}\u{7F}\u{85}\u{9B}") == #"\u{00}\u{07}\u{7F}\u{85}\u{9B}"#)
        #expect(Redact.oneLine("p\u{2028}q\u{2029}r") == #"p\u{2028}q\u{2029}r"#)
        #expect(Redact.oneLine("\u{202E}evil\u{2066}") == #"\u{202E}evil\u{2066}"#)
    }

    @Test func ordinaryTextIsUnchanged() {
        for text in ["plain", "naïve café", "日本語の件名", "👨‍👩‍👧 ❤️", "back\\slash", "fa\u{200C}rsi"] {
            #expect(Redact.oneLine(text) == text)
        }
    }

    @Test func theResultHasNoLineBreakOfAnyKind() {
        let nasty = (0..<0x20).map { String(UnicodeScalar($0)!) }.joined() + "\u{7F}\u{85}\u{2028}\u{2029}" + "\r\n"
        let line = Redact.oneLine(nasty)
        #expect(!line.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" })
        #expect(line.split(whereSeparator: \.isNewline).count == 1)
    }
}
