import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// One archive with every fixture except the 21 MB one, shared by the search tests.
final class SearchFixture: @unchecked Sendable {
    static let shared = try! SearchFixture()

    let root: URL
    let archive: Archive
    let searcher: MessageSearcher
    let account = AccountID(rawValue: "00000000-0000-4000-8000-0000000000aa")
    let otherAccount = AccountID(rawValue: "00000000-0000-4000-8000-0000000000bb")
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/eml", isDirectory: true)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-search-\(UUID().uuidString)")
        archive = try Archive.open(ArchiveLocation(root: root),
                                   keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        try archive.register(Account(id: account, provider: .microsoft, email: "sam@example.com", displayName: "Main"))
        try archive.register(Account(id: otherAccount, provider: .gmail, email: "sam@example.net", displayName: "Other"))
        let importer = Importer(archive: archive)
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path).filter { $0.hasSuffix(".eml") }.sorted()
        for (index, file) in files.enumerated() where !file.hasPrefix("05-") {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(file))
            // internal_date: 1 Sep 2025 plus one day per fixture number.
            let raw = RawMessage(key: RawMessageKey(accountID: account, folder: "INBOX", uidValidity: 1, uid: UInt32(index + 1)),
                                 internalDate: Date(timeIntervalSince1970: 1_756_684_800 + Double(index) * 86_400),
                                 size: data.count, bytes: data)
            _ = try importer.importMessage(raw)
        }
        // Ranking probes: the same rare word in a subject and in a body, in the other account.
        for (uid, subject, body) in [(1, "Notes", "The word zephyrine appears only here in the body."),
                                     (2, "Zephyrine plans", "Nothing much to say.")] {
            let text = "From: Probe <probe@example.net>\r\nTo: sam@example.net\r\nSubject: \(subject)\r\nDate: Mon, 1 Sep 2025 09:00:00 +0000\r\nMessage-ID: <probe-\(uid)@example.net>\r\n\r\n\(body)\r\n"
            let raw = RawMessage(key: RawMessageKey(accountID: otherAccount, folder: "INBOX", uidValidity: 1, uid: UInt32(uid)),
                                 internalDate: Date(timeIntervalSince1970: 1_756_684_800), size: text.utf8.count, bytes: Data(text.utf8))
            _ = try importer.importMessage(raw)
        }
        searcher = MessageSearcher(archive: archive)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func search(_ text: String) async throws -> [SearchHit] {
        try await searcher.search(QueryParser.parse(text))
    }
}

@Suite(.serialized) struct SearchTests {
    let fixture = SearchFixture.shared

    func subjects(_ query: String) async throws -> [String] {
        try await fixture.search(query).compactMap(\.subject)
    }

    @Test(arguments: [
        ("LANTERN-COAST-1150", "Walk on Saturday?", SearchField.body),
        ("MAGPIE-GALLERY-3307", nil, .body),
        ("PERIWINKLE-LEDGER-4471", "Q3 report", .attachmentText),
        ("MARIGOLD-MINUTES-9031", "Minutes", .attachmentText),
        ("GANNET-QUAY-6620", "Fwd: Boat trip details", .body),
        ("quarterly-report", "Q3 report", .attachmentName),
        ("allotment committee", nil, .subject),
        ("creme brulee", nil, .body),
    ] as [(String, String?, SearchField)])
    func findsTermsInEveryField(query: String, subject: String?, field: SearchField) async throws {
        let hits = try await fixture.search(query)
        #expect(!hits.isEmpty, "\(query)")
        if let subject { #expect(hits.first?.subject == subject, "\(query)") }
        #expect(hits.first?.matchedFields.contains(field) == true, "\(query): \(hits.first?.matchedFields ?? [])")
        #expect(hits.first?.snippet.contains("[") == true)
    }

    @Test func findsBySender() async throws {
        let hits = try await fixture.search("from:\"Jordan Lee\"")
        #expect(hits.isEmpty)  // Jordan sent the forwarded message, not the outer one
        let alex = try await fixture.search("from:alex")
        #expect(alex.count >= 5)
        #expect(alex.allSatisfy { $0.from?.address == "alex@example.org" })
        #expect(try await fixture.search("from:alex@example.org boat").first?.subject == "Fwd: Boat trip details")
    }

    @Test func subjectOutranksBody() async throws {
        let hits = try await fixture.search("zephyrine")
        #expect(hits.map(\.subject) == ["Zephyrine plans", "Notes"])
        #expect(hits[0].rank < hits[1].rank)
    }

    @Test func filters() async throws {
        let withAttachments = try await fixture.search("has:attachment")
        #expect(withAttachments.count == 7)  // 8 fixtures with attachments, minus the 21 MB one
        #expect(withAttachments.allSatisfy { $0.hasAttachments })
        #expect(try await fixture.search("report has:attachment").first?.subject == "Q3 report")
        #expect(try await fixture.search("report -has:attachment").allSatisfy { !$0.hasAttachments })

        let september = try await fixture.search("after:2025-09-02 before:2025-09-04")
        #expect(september.count == 2)
        let other = try await fixture.searcher.search(SearchQuery(text: "", accounts: [fixture.otherAccount]))
        #expect(other.count == 2)
        #expect(try await fixture.search("subject:minutes").first?.subject == "Minutes")
        #expect(try await fixture.search("to:residents").first?.subject == "Road closure")
    }

    @Test func prefixPhraseOrAndExclusion() async throws {
        // The PDF is in fixtures 06 and 07 (deduplicated to one file, still two messages).
        #expect(try await fixture.search("periwink*").count == 2)
        #expect(try await subjects("\"coastal walk\"") == ["Walk on Saturday?"])
        #expect(try await subjects("\"walk coastal\"").isEmpty)
        let either = try await subjects("zephyrine OR GANNET-QUAY-6620")
        #expect(Set(either) == ["Zephyrine plans", "Notes", "Fwd: Boat trip details"])
        #expect(try await subjects("zephyrine -plans") == ["Notes"])
    }

    @Test func hostileInputNeverBreaksTheQuery() async throws {
        for input in ["\"", "*", "AND", "OR", "NOT", "(", ")", "{subject}:", "a\"b", "^", "-", "NEAR(a b)", "' OR 1=1 --", "subject:"] {
            _ = try await fixture.search(input)
        }
        #expect(try await fixture.search("").isEmpty)
    }

    @Test func paging() async throws {
        let all = try await fixture.searcher.search(SearchQuery(text: "sam", limit: 100))
        let page = try await fixture.searcher.search(SearchQuery(text: "sam", limit: 3, offset: 3))
        #expect(all.count > 6)
        #expect(page.map(\.messageID) == Array(all.dropFirst(3).prefix(3)).map(\.messageID))
    }

    // MARK: OCR

    @Test func scannedPDFIsFoundAfterOCR() async throws {
        let before = try await fixture.search("Your letter")
        #expect(before.first?.ocrPending == true)
        #expect(try await fixture.search("SCANNED-HERON-2208").isEmpty)

        let queue = OCRQueue(archive: fixture.archive)
        #expect(try queue.status().pending == 1)
        let processed = try await queue.run()
        #expect(processed == 1)
        #expect(try queue.status() == OCRStatus(pending: 0, done: 1, failed: 0, messagesWaiting: 0))

        let hits = try await fixture.search("SCANNED-HERON-2208")
        #expect(hits.first?.subject == "Your letter")
        #expect(hits.first?.ocrPending == false)
        #expect(hits.first?.matchedFields.contains(.attachmentText) == true)
        // Running again finds nothing to do.
        #expect(try await queue.run() == 0)
    }
}

@Suite struct QueryParserTests {
    @Test func parsesFilters() {
        let query = QueryParser.parse("invoice from:\"Acme Ltd\" to:sam subject:q3 has:attachment account:abc after:2024-01-31 before:2024-03-01 10:30 re:")
        #expect(query.text == "invoice 10:30 re:")
        #expect(query.from == "Acme Ltd")
        #expect(query.to == "sam")
        #expect(query.subject == "q3")
        #expect(query.hasAttachment == true)
        #expect(query.accounts == [AccountID(rawValue: "abc")])
        #expect(query.since == Date(timeIntervalSince1970: 1_706_659_200))
        #expect(query.before == Date(timeIntervalSince1970: 1_709_251_200))
    }

    @Test func badDatesStayAsText() {
        #expect(QueryParser.parse("after:yesterday").text == "after:yesterday")
    }

    @Test(arguments: [
        ("invoice", "\"invoice\""),
        ("inv*", "\"inv\"*"),
        ("\"exact phrase\"", "\"exact phrase\""),
        ("a OR b", "(\"a\" OR \"b\")"),
        ("a -b", "(\"a\") NOT (\"b\")"),
        ("say \"hi", "\"say\" AND \"hi\""),
        ("-only", nil),
        ("!!! ---", nil),
    ] as [(String, String?)])
    func ftsExpressions(input: String, expected: String?) {
        #expect(FTSExpression.build(input) == expected)
    }

    @Test func columnFilter() {
        #expect(FTSExpression.build("alex", columns: ["from_text"]) == "{from_text} : (\"alex\")")
    }
}
