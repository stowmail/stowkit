import Foundation
import Testing

/// Checks that scripts/make-fixtures produced every case the Phase 0 brief lists.
/// Parsing the fixtures properly is Track B's job; these are byte-level checks only.
@Suite struct FixtureManifestTests {
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

        var owner: String
        var requiredCases: [String]
        var fixtures: [Fixture]
    }

    /// The cases listed in docs/briefs/phase-0-foundations.md, step 7.
    static let briefCases: Set<String> = [
        "plain-text", "html-only", "multipart-alternative", "inline-image", "attachment-15mb", "duplicate-pdf",
        "text-pdf", "scanned-pdf", "docx", "nested-rfc822", "iso-8859-1", "shift-jis", "rfc2047-subject",
        "rfc2231-filename", "missing-message-id", "malformed-date", "long-header-lines", "list-unsubscribe",
        "precedence-bulk", "noreply-sender", "reply-to-differs", "sixty-recipients", "bcc-only", "calendar-invite",
    ]

    let manifest: Manifest

    init() throws {
        let url = Self.directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            Issue.record("Fixtures missing: run scripts/make-fixtures (scripts/check.sh does this)")
            throw CocoaError(.fileNoSuchFile)
        }
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
    }

    func bytes(_ file: String) throws -> Data {
        try Data(contentsOf: Self.directory.appendingPathComponent(file))
    }

    /// The header block: everything before the first blank line.
    func headerBlock(_ file: String) throws -> String {
        let data = try bytes(file)
        let end = data.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? data.endIndex
        return String(decoding: data[..<end], as: UTF8.self)
    }

    func fixtures(for testCase: String) -> [Manifest.Fixture] {
        manifest.fixtures.filter { $0.cases.contains(testCase) }
    }

    @Test func everyBriefCaseIsCovered() {
        #expect(Set(manifest.requiredCases) == Self.briefCases)
        let covered = Set(manifest.fixtures.flatMap(\.cases))
        #expect(Self.briefCases.subtracting(covered).isEmpty, "missing: \(Self.briefCases.subtracting(covered))")
    }

    @Test func everyFileExistsUsesCRLFAndHasHeaders() throws {
        for fixture in manifest.fixtures {
            let data = try bytes(fixture.file)
            #expect(data.range(of: Data("\r\n\r\n".utf8)) != nil, "\(fixture.file)")
            // No bare LF line endings anywhere.
            let bareLF = zip(data.dropLast(), data.dropFirst()).contains { $0 != 0x0D && $1 == 0x0A } || data.first == 0x0A
            #expect(!bareLF, "\(fixture.file) has a bare LF")
        }
    }

    @Test func onlyReservedExampleDomainsAreUsed() throws {
        let pattern = try NSRegularExpression(pattern: #"@([A-Za-z0-9.-]+\.[A-Za-z]{2,})"#)
        let reserved = ["example.com", "example.org", "example.net", "mcsv.net"]
        for fixture in manifest.fixtures {
            let header = try headerBlock(fixture.file)
            for match in pattern.matches(in: header, range: NSRange(header.startIndex..., in: header)) {
                let domain = (header as NSString).substring(with: match.range(at: 1)).lowercased()
                #expect(reserved.contains { domain == $0 || domain.hasSuffix(".\($0)") }, "\(fixture.file): \(domain)")
            }
        }
    }

    @Test func largeAttachmentIsFifteenMebibytes() throws {
        let fixture = try #require(fixtures(for: "attachment-15mb").first)
        #expect(fixture.attachments.first?.bytes == 15 * 1024 * 1024)
        #expect(try bytes(fixture.file).count > 15 * 1024 * 1024 * 4 / 3)
    }

    @Test func duplicatePDFIsIdenticalInTwoDifferentMessages() throws {
        let pair = fixtures(for: "duplicate-pdf")
        #expect(pair.count == 2)
        let pdfs = pair.compactMap { $0.attachments.first { $0.mimeType == "application/pdf" } }
        #expect(pdfs.count == 2)
        #expect(Set(pdfs.map(\.sha256)).count == 1)
        #expect(Set(pdfs.map(\.filename)).count == 2)
        #expect(try headerBlock(pair[0].file) != headerBlock(pair[1].file))
    }

    @Test func charsetFixturesHoldRawNonUTF8Bytes() throws {
        let latin1 = try bytes(try #require(fixtures(for: "iso-8859-1").first).file)
        #expect(latin1.contains(0xE9)) // é in ISO-8859-1
        #expect(String(data: latin1, encoding: .utf8) == nil)

        let sjis = try headerBlock(try #require(fixtures(for: "shift-jis").first).file)
        #expect(sjis.contains("=?Shift_JIS?B?"))
    }

    @Test func headerEdgeCases() throws {
        let missingID = try headerBlock(try #require(fixtures(for: "missing-message-id").first).file)
        #expect(!missingID.lowercased().contains("\r\nmessage-id:"))

        let longLines = try headerBlock(try #require(fixtures(for: "long-header-lines").first).file)
        #expect(longLines.components(separatedBy: "\r\n").contains { $0.count > 998 })

        let encoded = try headerBlock(try #require(fixtures(for: "rfc2047-subject").first).file)
        #expect(encoded.contains("=?UTF-8?B?") && encoded.contains("=?UTF-8?Q?"))

        let rfc2231 = try String(decoding: bytes(try #require(fixtures(for: "rfc2231-filename").first).file), as: UTF8.self)
        #expect(rfc2231.contains("filename*=UTF-8''") && rfc2231.contains("filename*1*="))
    }

    @Test func bulkSignalFixturesCarryTheirSignal() throws {
        func header(_ testCase: String) throws -> String {
            try headerBlock(try #require(fixtures(for: testCase).first { $0.cases.count == 1 }).file).lowercased()
        }
        #expect(try header("list-unsubscribe").contains("\r\nlist-unsubscribe:"))
        #expect(try header("precedence-bulk").contains("\r\nprecedence: bulk"))
        #expect(try header("noreply-sender").contains("no-reply@"))
        #expect(try header("reply-to-differs").contains("\r\nreply-to:"))
        #expect(try header("bcc-only").contains("delivered-to: \(manifest.owner)"))

        let sixty = try header("sixty-recipients")
        #expect(sixty.components(separatedBy: "@example.").count - 1 >= 60)
    }

    @Test func personalFixturesAreMarked() {
        let personal = manifest.fixtures.filter(\.personal).flatMap(\.cases)
        #expect(personal.contains("plain-text"))
        #expect(!personal.contains("list-unsubscribe"))
    }
}
