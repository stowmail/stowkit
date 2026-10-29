import Foundation
import StowCore
import Testing
@testable import StowRules

/// A-19 (D-517): if the protection lists cannot be loaded, nothing is suggested
/// for removal and the problem is visible; never a crash.
struct RulesDataLoadTests {
    /// An invoice from a listed billing address, with two strong bulk signals.
    let invoice = HeaderParser().parseHeaders(Data("""
        From: PayPal <service@paypal.com>\r
        To: sam@example.com\r
        Subject: Your receipt\r
        List-Unsubscribe: <https://x.example/u>\r
        Precedence: bulk\r
        \r

        """.utf8))
    let offer = HeaderParser().parseHeaders(Data("From: news@shop.example\r\nTo: sam@example.com\r\nSubject: Sale\r\nList-Unsubscribe: <https://x.example/u>\r\nPrecedence: bulk\r\n\r\n".utf8))

    func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rules-data-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let complete = #"{"version": 2, "noReplyLocalParts": ["noreply"], "listProviderDomains": ["mailchimp.com"], "protectedSubjectKeywords": ["invoice"], "protectedSenderKeywords": ["billing"], "billingSenders": ["service@paypal.com"]}"#

    func expectFailsClosed(_ data: RulesData, _ problem: RulesDataProblem) {
        #expect(data.loadProblem == problem)
        for headers in [invoice, offer] {
            let assessment = RuleSet.standard.assess(headers, data: data)
            #expect(assessment.suggestion == .keep)
            #expect(assessment.rulesUnavailable)
            #expect(assessment.reasons == [RulesDataProblem.message])
        }
        // Even a user's override cannot make a suggestion.
        var set = RuleSet.standard
        set.senderOverrides = [SenderOverride(match: "shop.example", suggestion: .considerDeletingFromSource)]
        #expect(set.assess(offer, data: data).suggestion == .keep)
        #expect(problem.description.hasPrefix("Stow could not read its list of protected senders"))
    }

    @Test func aMissingFile() {
        expectFailsClosed(RulesData.load(from: URL(fileURLWithPath: "/nonexistent/rules-data.json")), .missing)
        expectFailsClosed(RulesData.load(from: nil), .missing)
    }

    @Test func aBrokenFile() throws {
        expectFailsClosed(RulesData.load(from: try file("{ not json")), .unreadable)
        expectFailsClosed(RulesData.load(from: try file(#"{"version": 2, "noReplyLocalParts": ["noreply"], "listProviderDomains": []}"#)), .unreadable)
    }

    @Test func aFileWithAnEmptyList() throws {
        let empty = Self.complete.replacingOccurrences(of: #"["service@paypal.com"]"#, with: "[]")
        expectFailsClosed(RulesData.load(from: try file(empty)), .emptyList("billingSenders"))
    }

    @Test func aGoodFileWorksAsBefore() throws {
        let data = RulesData.load(from: try file(Self.complete))
        #expect(data.loadProblem == nil)
        #expect(RuleSet.standard.assess(invoice, data: data).protection?.kind == .billingSender)
        #expect(RuleSet.standard.assess(offer, data: data).suggestion == .considerDeletingFromSource)
    }

    /// Fails if someone empties a list in the shipped file.
    @Test func theBundledFileLoadsWithEveryListFilled() {
        let data = RulesData.bundled
        #expect(data.loadProblem == nil)
        #expect(data.emptyLists.isEmpty)
        #expect(!data.noReplyLocalParts.isEmpty && !data.listProviderDomains.isEmpty && !data.protectedSubjectKeywords.isEmpty
                && !data.protectedSenderKeywords.isEmpty && !data.billingSenders.isEmpty)
    }
}
