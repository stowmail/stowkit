import Foundation
import Testing
@testable import StowCore

/// A-02 (security sweep 1): hostile encoded words must decode in linear time
/// wherever they appear. The old decoder took minutes or more on each of
/// these inputs; the one-second bound leaves a wide gap between linear and
/// quadratic. If a slower machine needs it, shrink the input, not the bound.
@Suite(.timeLimit(.minutes(1))) struct EncodedWordsTimingTests {
    static let size = 1 << 20

    /// Every failed `=?` scanned to the end to see whether it looked like a word.
    @Test func repeatedMarkers() {
        let value = String(repeating: "=?", count: Self.size / 2)
        let (decoded, seconds) = timed { EncodedWords.decode(value) }
        #expect(seconds < 1, "took \(seconds) s")
        #expect(decoded.text == value)
        #expect(decoded.hadProblem)
    }

    @Test func repeatedCharsetOnly() {
        let value = String(repeating: "=?x?", count: Self.size / 4)
        let (decoded, seconds) = timed { EncodedWords.decode(value) }
        #expect(seconds < 1, "took \(seconds) s")
        #expect(decoded.text == value)
    }

    /// A word whose encoded text never ends: the word parser itself scanned to the end.
    @Test func encodedTextNeverEnds() {
        let value = String(repeating: "=?a?q?x", count: Self.size / 7)
        let (decoded, seconds) = timed { EncodedWords.decode(value) }
        #expect(seconds < 1, "took \(seconds) s")
        #expect(decoded.text == value)
    }

    @Test func displayName() {
        let name = String(repeating: "=?", count: Self.size / 2)
        let (parsed, seconds) = timed { AddressListParser.parse("\(name) <sam@example.org>") }
        #expect(seconds < 1, "took \(seconds) s")
        #expect(parsed.addresses.map(\.address) == ["sam@example.org"])
    }

    /// Half the size, to stay under the 1 MB header block cap.
    @Test func subjectThroughHeaderParser() {
        let subject = String(repeating: "=?x?", count: Self.size / 8)
        let block = "From: sam@example.org\r\nSubject: \(subject)\r\n\r\n"
        let (headers, seconds) = timed { HeaderParser().parseHeaders(Data(block.utf8)) }
        #expect(seconds < 1, "took \(seconds) s")
        #expect(headers.subject == subject)
    }
}

/// The bounds added for A-02 leave real encoded words alone (D-494).
@Suite struct EncodedWordsBoundsTests {
    /// A folded Subject of 800 valid words, about 22 KB: words starting in
    /// the first 16 KB decode as before, later ones are kept as written.
    @Test func longFoldedSubjectDecodesUpToTheCap() {
        let words = (0..<800).map { "=?utf-8?q?Caf=C3=A9_\(String(format: "%04d", $0))?=" }
        var cut = 0
        var offset = 0
        while cut < words.count, offset < EncodedWords.maximumScannedBytes {
            offset += words[cut].utf8.count + 1
            cut += 1
        }
        #expect(cut > 1 && cut < words.count)
        let decodedPart = (0..<cut).map { "Café \(String(format: "%04d", $0))" }.joined()
        let expected = decodedPart + " " + words[cut...].joined(separator: " ")

        let block = "Subject: " + words.joined(separator: "\r\n ") + "\r\n\r\n"
        let headers = HeaderParser().parseHeaders(Data(block.utf8))
        #expect(headers.subject == expected)
        #expect(headers.warnings.contains("undecodable encoded word in Subject"))
        // Up to the cap, the same as decoding those words on their own.
        #expect(EncodedWords.decode(words[..<cut].joined(separator: " ")).text == decodedPart)
    }

    /// RFC 2047's longest word, 75 bytes, still decodes; a much longer one is kept as written.
    @Test func wordLength() {
        let longest = "=?utf-8?q?" + String(repeating: "a", count: 75 - 12) + "?="
        #expect(longest.utf8.count == 75)
        #expect(EncodedWords.decode(longest).text == String(repeating: "a", count: 63))
        let tooLong = "=?utf-8?q?" + String(repeating: "a", count: 100) + "?="
        #expect(EncodedWords.decode(tooLong).text == tooLong)
    }
}

func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try body()
    let elapsed = clock.now - start
    return (result, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}
