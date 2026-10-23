import CryptoKit
import Foundation
import Testing
@testable import StowStore

/// Shared access to the generated fixtures (D-018).
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/eml", isDirectory: true)

    struct Manifest: Decodable {
        struct Attachment: Decodable {
            var filename: String
            var mimeType: String
            var bytes: Int
            var sha256: String
        }

        struct Fixture: Decodable {
            var file: String
            var cases: [String]
            var personal: Bool
            var attachments: [Attachment]
        }

        var fixtures: [Fixture]
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    static func data(_ prefix: String) throws -> Data {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let file = try #require(files.first { $0.hasPrefix(prefix) && $0.hasSuffix(".eml") })
        return try Data(contentsOf: directory.appendingPathComponent(file))
    }

    static func allFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".eml") }.sorted()
    }
}

@Suite struct MIMEParserTests {
    let parser = MIMEParser()

    func parse(_ prefix: String) throws -> ParsedMessage {
        parser.parse(try Fixtures.data(prefix))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func everyFixtureMatchesTheManifestsAttachments() throws {
        for fixture in try Fixtures.manifest().fixtures {
            let parsed = parser.parse(try Data(contentsOf: Fixtures.directory.appendingPathComponent(fixture.file)))
            #expect(parsed.status != .failed, "\(fixture.file)")
            #expect(parsed.bodyText?.isEmpty == false, "\(fixture.file)")
            for expected in fixture.attachments {
                let match = parsed.attachments.first { $0.filename == expected.filename }
                #expect(match != nil, "\(fixture.file): \(expected.filename)")
                if let match {
                    #expect(match.data.count == expected.bytes, "\(fixture.file)")
                    #expect(Self.sha256(match.data) == expected.sha256, "\(fixture.file)")
                    #expect(match.declaredMimeType == expected.mimeType, "\(fixture.file)")
                }
            }
        }
    }

    @Test func wellFormedFixturesParseCleanly() throws {
        for file in try Fixtures.allFiles() where !file.hasPrefix("15-") && !file.hasPrefix("16-") {
            let parsed = parser.parse(try Data(contentsOf: Fixtures.directory.appendingPathComponent(file)))
            #expect(parsed.status == .ok, "\(file): \(parsed.warnings)")
        }
    }

    @Test func malformedFixturesAreFlagged() throws {
        #expect(try parse("15-").status == .degraded)
        #expect(try parse("16-").status == .degraded)
    }

    @Test func plainAndHTMLBodies() throws {
        #expect(try parse("01-").textPlain?.contains("LANTERN-COAST-1150") == true)
        let html = try parse("02-")
        #expect(html.textPlain == nil)
        #expect(html.textFromHTML?.contains("MAGPIE-GALLERY-3307") == true)
        #expect(html.textFromHTML?.contains("<") == false)
        let alternative = try parse("03-")
        #expect(alternative.textPlain?.contains("OLIVE-TABLE-5512") == true)
        #expect(alternative.textFromHTML?.contains("Italian place") == true)
    }

    @Test func inlineImageIsInlineWithContentID() throws {
        let parsed = try parse("04-")
        let image = try #require(parsed.attachments.first)
        #expect(image.disposition == .inline)
        #expect(image.contentID == "club-logo@example.org")
        #expect(image.partPath == "2")
    }

    @Test func charsetsDecode() throws {
        #expect(try parse("11-").textPlain?.contains("crème brûlée") == true)
        #expect(try parse("12-").textPlain?.contains("SAKURA-KAIGI-4402") == true)
        #expect(try parse("12-").textPlain?.contains("会議の資料") == true)
    }

    @Test func forwardedMessageIsOpened() throws {
        let parsed = try parse("10-")
        #expect(parsed.textPlain?.contains("GANNET-QUAY-6620") == true)
        #expect(parsed.textPlain?.contains("Jordan Lee") == true)
        let checklist = try #require(parsed.attachments.first { $0.filename == "checklist.txt" })
        #expect(checklist.partPath == "2.2")
    }

    @Test func rfc2231FileNames() throws {
        let names = try parse("14-").attachments.compactMap(\.filename)
        #expect(names == ["résumé — final.txt", "very long name split across parameters.txt"])
    }

    @Test func calendarInviteKeepsTextBodyAndListsInvite() throws {
        let parsed = try parse("24-")
        #expect(parsed.textPlain?.contains("Planning meeting") == true)
        #expect(parsed.attachments.contains { $0.filename == "invite.ics" })
    }

    @Test func largeAttachmentRoundTrips() throws {
        let parsed = try parse("05-")
        #expect(parsed.attachments.first?.data.count == 15 * 1024 * 1024)
    }

    // MARK: Malformed input

    @Test func missingClosingBoundary() {
        let raw = "From: a@example.com\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\nhello\r\n"
        let parsed = parser.parse(Data(raw.utf8))
        #expect(parsed.textPlain == "hello\n")
        #expect(parsed.warnings.contains("multipart without closing boundary"))
    }

    @Test func missingBoundaryReadsAsText() {
        let raw = "From: a@example.com\r\nContent-Type: multipart/mixed\r\n\r\nhello"
        let parsed = parser.parse(Data(raw.utf8))
        #expect(parsed.textPlain == "hello")
        #expect(parsed.status == .degraded)
    }

    @Test func emptyInputFails() {
        #expect(parser.parse(Data()).status == .failed)
    }

    @Test func deepNestingStops() {
        var raw = "From: a@example.com\r\n"
        for level in 0..<50 {
            raw += "Content-Type: multipart/mixed; boundary=b\(level)\r\n\r\n--b\(level)\r\n"
        }
        raw += "\r\nbottom\r\n"
        let parsed = parser.parse(Data(raw.utf8))
        #expect(parsed.warnings.contains("MIME nesting too deep, rest skipped"))
    }

    @Test func randomMutationsNeverCrash() throws {
        let seeds = try ["03-", "04-", "10-", "14-", "24-"].map { try Fixtures.data($0) }
        var generator = SystemRandomNumberGenerator()
        for seed in seeds {
            for _ in 0..<200 {
                var bytes = [UInt8](seed)
                for _ in 0..<Int.random(in: 1...20, using: &generator) {
                    let index = Int.random(in: 0..<bytes.count, using: &generator)
                    switch Int.random(in: 0..<3, using: &generator) {
                    case 0: bytes[index] = UInt8.random(in: 0...255, using: &generator)
                    case 1: bytes.remove(at: index)
                    default: bytes.insert(Array("-=\r\n;\"".utf8).randomElement()!, at: index)
                    }
                }
                _ = parser.parse(Data(bytes))
            }
        }
    }

    // MARK: Pieces

    @Test func contentFieldParameters() {
        let field = ContentField.parse("Text/Plain; charset=\"utf-8\" (comment); format=flowed")
        #expect(field.value == "text/plain")
        #expect(field[parameter: "charset"] == "utf-8")
        #expect(field[parameter: "FORMAT"] == "flowed")
        #expect(ContentField.parse("attachment; filename=\"=?UTF-8?Q?caf=C3=A9.txt?=\"")[parameter: "filename"] == "café.txt")
        #expect(ContentField.parse("attachment; filename*=iso-8859-1'fr'caf%E9.txt")[parameter: "filename"] == "café.txt")
    }

    @Test func quotedPrintable() {
        let input = Array("caf=C3=A9 =\r\nsoft=3D x=ZZ".utf8)
        let output = TransferDecoding.quotedPrintable(input, 0..<input.count)
        #expect(String(decoding: output, as: UTF8.self) == "café soft= x=ZZ")
    }

    @Test func lenientBase64() {
        let input = Array("Y2Fm\r\nw6k\r\n".utf8)
        let (data, _) = TransferDecoding.base64(input, 0..<input.count)
        #expect(String(decoding: data, as: UTF8.self) == "café")
    }

    @Test func htmlToText() {
        let html = "<html><head><style>p{}</style><title>T</title></head><body><!-- x --><p>One&nbsp;&amp; two</p><script>var a</script><br>Three &#8364; &#x263A; &unknown;</body></html>"
        #expect(HTMLText.text(fromHTML: html) == "One & two\n\nThree € ☺ &unknown;")
    }
}
