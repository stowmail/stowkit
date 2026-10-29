import Foundation
import Testing
@testable import StowCore

@Suite struct HeaderParserTests {
    static let directory = FixtureManifestTests.directory
    let parser = HeaderParser()

    func fixture(_ prefix: String) throws -> MessageHeaders {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
        let file = try #require(files.first { $0.hasPrefix(prefix) && $0.hasSuffix(".eml") })
        return parser.parseHeaders(try Data(contentsOf: Self.directory.appendingPathComponent(file)))
    }

    func parse(_ text: String) -> MessageHeaders {
        parser.parseHeaders(Data(text.utf8))
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, offsetHours: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    // MARK: Fixtures

    @Test func everyFixtureParsesWithAFromAddress() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).filter { $0.hasSuffix(".eml") }
        #expect(files.count >= 25)
        for file in files {
            let headers = parser.parseHeaders(try Data(contentsOf: Self.directory.appendingPathComponent(file)))
            #expect(headers.from.count == 1, "\(file)")
            #expect(headers.subject != nil, "\(file)")
        }
    }

    @Test func plainText() throws {
        let h = try fixture("01-")
        #expect(h.from == [EmailAddress(name: "Alex Morgan", address: "alex@example.org")])
        #expect(h.to == [EmailAddress(name: "Sam Taylor", address: "sam@example.com")])
        #expect(h.subject == "Walk on Saturday?")
        #expect(h.date == Self.date(2025, 9, 2, 9, 1, 0, offsetHours: 1))
        #expect(h.messageID == "fixture-1@mail.example.org")
        #expect(h.deliveredTo.map(\.address) == ["sam@example.com"])
        #expect(h.value(named: "Return-Path") == "<alex@example.org>")
        #expect(h.warnings.isEmpty)
        #expect(h.fields.first?.name == "Return-Path")
    }

    @Test func isoLatin1EncodedWords() throws {
        let h = try fixture("11-")
        #expect(h.from.first?.name == "Renée Dupont")
        #expect(h.subject == "Café près de la gare")
        #expect(h.warnings.isEmpty)
    }

    @Test func shiftJISEncodedWords() throws {
        let h = try fixture("12-")
        #expect(h.from.first?.name == "田中 健")
        #expect(h.subject?.isEmpty == false)
        #expect(h.subject?.contains("=?") == false)
        #expect(h.warnings.isEmpty)
    }

    @Test func multiLineRFC2047SubjectMatchesTheBodysStatement() throws {
        let h = try fixture("13-")
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
        let file = try #require(files.first { $0.hasPrefix("13-") })
        let text = String(decoding: try Data(contentsOf: Self.directory.appendingPathComponent(file)), as: UTF8.self)
        let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("Subject decodes to: ") })
        let expected = String(line.dropFirst("Subject decodes to: ".count)).trimmingCharacters(in: .whitespaces)
        #expect(h.subject == expected)
        #expect(h.from.first?.name == "Zoë Åberg")
    }

    @Test func missingMessageIDIsFlagged() throws {
        let h = try fixture("15-")
        #expect(h.messageID == nil)
        #expect(h.warnings.contains("missing Message-ID"))
    }

    @Test func malformedDateIsFlaggedAndKept() throws {
        let h = try fixture("16-")
        #expect(h.date == nil)
        #expect(h.dateRaw == "Thursday, 32 Smarch 2025 25:61:00 +9900")
        #expect(h.warnings == ["malformed Date"])
    }

    @Test func longFoldedHeadersUnfold() throws {
        let h = try fixture("17-")
        #expect(h.subject?.contains("\r") == false)
        #expect(h.subject?.contains("\n") == false)
        #expect(h.subject?.hasSuffix("rota for watering in August") == true)
        #expect(h.references.count >= 30)
        #expect(h.references.first == "thread-1-reference@mail.example.org")
    }

    @Test func listHeadersKeptRawAndUnfolded() throws {
        let h = try fixture("18-")
        #expect(h.listUnsubscribe == "<mailto:unsubscribe@news.example.com?subject=unsubscribe>, <https://news.example.com/unsubscribe/opaque-id>")
        #expect(h.listUnsubscribePost == "List-Unsubscribe=One-Click")
        #expect(h.listID == "Garden Weekly <weekly.news.example.com>")
    }

    @Test func precedenceLowercased() throws {
        #expect(try fixture("19-").precedence == "bulk")
        #expect(try fixture("01-").precedence == nil)
    }

    @Test func replyToParsed() throws {
        let h = try fixture("21-")
        #expect(h.replyTo == [EmailAddress(name: "Bookings", address: "bookings@agency.example.net")])
    }

    @Test func sixtyRecipients() throws {
        #expect(try fixture("22-").recipientCount == 60)
    }

    @Test func bccOnlyHasOwnerInDeliveredToOnly() throws {
        let h = try fixture("23-")
        #expect(!(h.to + h.cc).contains { $0.normalised == "sam@example.com" })
        #expect(h.deliveredTo.map(\.normalised) == ["sam@example.com"])
    }

    @Test func newsletterKeepsReturnPathAndOtherRawFields() throws {
        let h = try fixture("25-")
        #expect(h.value(named: "Return-Path")?.contains("mcsv.net") == true)
        #expect(h.value(named: "X-Mailer") == "MailChimp Mailer")
        #expect(h.precedence == "bulk")
        #expect(h.from.first?.localPart == "noreply")
    }

    // MARK: Header block

    @Test func bareLineFeedsAndHeaderOnlyInput() {
        let h = parse("From: a@example.com\nSubject: Hi\n there\nDate: Mon, 2 Sep 2025 09:01 +0000")
        #expect(h.subject == "Hi there")
        #expect(h.date == Self.date(2025, 9, 2, 9, 1, 0, offsetHours: 0))
    }

    @Test func bodyStartIsAfterTheBlankLine() {
        var warnings: [String] = []
        let data = Data("A: 1\r\nB: 2\r\n\r\nbody".utf8)
        let block = HeaderParser.splitFields(data, warnings: &warnings)
        #expect(block.fields.map(\.name) == ["A", "B"])
        #expect(String(decoding: data[block.bodyStart...], as: UTF8.self) == "body")
        #expect(warnings.isEmpty)
    }

    @Test func badLinesAreSkippedWithWarnings() {
        let h = parse(" stray continuation\r\nFrom sam@example.com Mon Sep 2 2025\r\nFrom: a@example.com\r\nnonsense\r\n\r\n")
        #expect(h.fields.map(\.name) == ["From"])
        #expect(h.warnings.contains("continuation line before any header"))
        #expect(h.warnings.contains("header line without a colon skipped"))
    }

    @Test func eightBitLatin1HeaderFallsBack() {
        var data = Data("From: a@example.com\r\nSubject: Caf".utf8)
        data.append(0xE9)
        data.append(contentsOf: Data("\r\n\r\n".utf8))
        let h = parser.parseHeaders(data)
        #expect(h.subject == "Café")
        #expect(h.warnings.contains("8-bit header bytes that are not UTF-8"))
    }

    @Test func rawUTF8HeadersAccepted() {
        let h = parse("From: Zoë <zoe@example.org>\r\nSubject: Grüße\r\n\r\n")
        #expect(h.subject == "Grüße")
        #expect(h.from.first?.name == "Zoë")
    }

    @Test func warningsNeverContainHeaderValues() {
        let secret = "SECRET-VALUE-9931"
        let h = parse("From: \(secret) <broken\r\nDate: \(secret)\r\nSubject: =?bogus-set?Q?\(secret)?=\r\nTo: \(secret)\r\n\r\n")
        #expect(!h.warnings.isEmpty)
        #expect(!h.warnings.joined().contains(secret))
    }

    @Test func randomBytesNeverCrash() {
        var generator = SeededGenerator(seed: 42)
        let alphabet = Array("From:To:Cc:Date:<>\"(),;:@=?Qq?Bb\r\n \t abcxyz.=?utf-8?".utf8) + [0xFF, 0x80, 0x00]
        for _ in 0..<2000 {
            let length = Int.random(in: 0..<400, using: &generator)
            let bytes = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }
            _ = parser.parseHeaders(Data(bytes))
        }
    }

    @Test func oversizedHeaderBlockIsTruncated() {
        let line = "X-Filler: " + String(repeating: "a", count: 1000) + "\r\n"
        let big = String(repeating: line, count: 1200)
        let h = parse("From: a@example.com\r\n" + big + "\r\nbody")
        #expect(h.warnings.contains { $0.hasPrefix("header block truncated") })
        #expect(h.from.count == 1)
    }

    // MARK: Encoded words

    @Test(arguments: [
        ("=?utf-8?q?caf=C3=A9?=", "café"),
        ("=?UTF-8?Q?a_b?= =?UTF-8?Q?c?=", "a bc"),
        ("=?utf-8?b?Y2Fmw6k?=", "café"),  // missing padding
        ("plain =?utf-8?q?x?= text", "plain x text"),
        ("=?utf-8*en?q?hi?=", "hi"),
        ("=?utf-8?q?=E2=82?= =?utf-8?q?=AC?=", "€"),  // multi-byte character split across words
        ("no words here", "no words here"),
        ("=?utf-8?x?bad?=", "=?utf-8?x?bad?="),
        ("100% =?", "100% =?"),
    ])
    func encodedWords(input: String, expected: String) {
        #expect(EncodedWords.decode(input).text == expected)
    }

    @Test func unknownCharsetLeftAsWrittenAndFlagged() {
        let result = EncodedWords.decode("=?x-klingon?q?abc?=")
        #expect(result.text == "=?x-klingon?q?abc?=")
        #expect(result.hadProblem)
    }

    // MARK: Addresses

    @Test(arguments: [
        ("a@example.com", [EmailAddress(address: "a@example.com")]),
        ("<a@example.com>", [EmailAddress(address: "a@example.com")]),
        ("\"Taylor, Sam\" <sam@example.com>", [EmailAddress(name: "Taylor, Sam", address: "sam@example.com")]),
        ("sam@example.com (Sam Taylor)", [EmailAddress(name: "Sam Taylor", address: "sam@example.com")]),
        ("Team: a@example.com, B <b@example.com>;, c@example.com",
         [EmailAddress(address: "a@example.com"), EmailAddress(name: "B", address: "b@example.com"), EmailAddress(address: "c@example.com")]),
        ("undisclosed-recipients:;", []),
        ("<@relay.example.net:a@example.com>", [EmailAddress(address: "a@example.com")]),
        ("Alex Morgan alex@example.org", [EmailAddress(name: "Alex Morgan", address: "alex@example.org")]),
        ("\"john doe\"@example.com", [EmailAddress(address: "\"john doe\"@example.com")]),
        ("a@example.com,, ,b@example.com", [EmailAddress(address: "a@example.com"), EmailAddress(address: "b@example.com")]),
        ("=?utf-8?q?Zo=C3=AB?= <zoe@example.org>", [EmailAddress(name: "Zoë", address: "zoe@example.org")]),
        ("\"=?utf-8?q?Zo=C3=AB?=\" <zoe@example.org>", [EmailAddress(name: "Zoë", address: "zoe@example.org")]),
        ("<mailto:a@example.com>", [EmailAddress(address: "a@example.com")]),
    ])
    func addressLists(input: String, expected: [EmailAddress]) {
        #expect(AddressListParser.parse(input).addresses == expected)
    }

    @Test func addressWithoutAtIsDroppedAndFlagged() {
        let result = AddressListParser.parse("Residents, a@example.com")
        #expect(result.addresses == [EmailAddress(address: "a@example.com")])
        #expect(result.hadProblem)
    }

    @Test func messageIDs() {
        #expect(AddressListParser.messageIDs("<a@x> (comment) <b@y>") == ["a@x", "b@y"])
        #expect(AddressListParser.messageIDs("bare-id@x") == ["bare-id@x"])
        #expect(AddressListParser.messageIDs("") == [])
    }

    /// Swift reads CR LF as one Character, which the tokeniser once never
    /// moved past (A-22). Header values never hold a line feed, but callers of
    /// the public API can pass one.
    @Test func crlfIsWhitespace() {
        #expect(AddressListParser.parse("a\r\nb").addresses == [])
        #expect(AddressListParser.parse("Sam <sam@example.org>,\r\n alex@example.org").addresses
            == [EmailAddress(name: "Sam", address: "sam@example.org"), EmailAddress(address: "alex@example.org")])
        #expect(AddressListParser.messageIDs("<a@x>\r\n<b@y>") == ["a@x", "b@y"])
    }

    // MARK: Dates

    @Test(arguments: [
        ("Mon, 02 Sep 2025 09:01:00 +0100", 2025, 9, 2, 9, 1, 0, 1),
        ("2 Sep 2025 09:01 +0100", 2025, 9, 2, 9, 1, 0, 1),
        ("Mon, 2 Sep 25 09:01:00 GMT", 2025, 9, 2, 9, 1, 0, 0),
        ("Mon, 2 Sep 99 09:01:00 EST", 1999, 9, 2, 9, 1, 0, -5),
        ("Mon, 2 Sep 2025 09:01:00 -0000 (UTC)", 2025, 9, 2, 9, 1, 0, 0),
        ("Mon Sep  2 09:01:00 2025", 2025, 9, 2, 9, 1, 0, 0),
        ("Mon, 2 September 2025 09:01:60 +0000", 2025, 9, 2, 9, 1, 59, 0),
        ("29 Feb 2024 00:00:00 +0000", 2024, 2, 29, 0, 0, 0, 0),
    ])
    func dates(raw: String, y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int, offset: Int) {
        #expect(MessageDateParser.parse(raw)?.date == Self.date(y, mo, d, h, mi, s, offsetHours: offset))
    }

    @Test(arguments: [
        "Thursday, 32 Smarch 2025 25:61:00 +9900",
        "29 Feb 2025 00:00:00 +0000",
        "2025-09-02T09:01:00Z",
        "",
        "Mon, 2 Sep 2025",
        "next Tuesday",
    ])
    func badDates(raw: String) {
        #expect(MessageDateParser.parse(raw) == nil)
    }

    @Test func missingZoneAssumesUTC() {
        let result = MessageDateParser.parse("2 Sep 2025 09:01:00")
        #expect(result?.assumedUTC == true)
        #expect(result?.date == Self.date(2025, 9, 2, 9, 1, 0, offsetHours: 0))
    }

    // MARK: Charsets

    @Test func charsetLookups() {
        #expect(Charset.encoding(named: "UTF-8") == .utf8)
        #expect(Charset.encoding(named: "iso-8859-1") == .windowsCP1252)
        #expect(Charset.encoding(named: "Shift_JIS") != nil)
        #expect(Charset.encoding(named: "\"koi8-r\"") != nil)
        #expect(Charset.encoding(named: "x-unknown") == nil)
        #expect(Charset.decode([0x41, 0x81], charset: "us-ascii").text == "A\u{81}")
        #expect(Charset.decode([0xE2, 0x82, 0xAC], charset: nil) == Charset.Decoded(text: "€", usedFallback: false))
    }

    @Test func keywordStripsParametersAndComments() {
        #expect(HeaderParser.keyword(" Auto-Generated; owner=x") == "auto-generated")
        #expect(HeaderParser.keyword("bulk (yes)") == "bulk")
        #expect(HeaderParser.keyword("  ") == nil)
    }
}

/// A small deterministic random number generator, so the robustness test is repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
