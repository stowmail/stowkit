import Foundation
import StowCore
import Testing
@testable import StowRules

/// Protected mail (UI-10, D-407): never suggested for removal, with the reason.
struct ProtectionTests {
    /// A bulk message (two strong signals: consider deleting) from `from` with `subject`.
    func bulk(from: String, subject: String) -> MessageHeaders {
        HeaderParser().parseHeaders(Data("""
            From: \(from)\r
            To: sam@example.com\r
            Subject: \(subject)\r
            List-Unsubscribe: <https://shop.example/u>\r
            Precedence: bulk\r
            Message-ID: <p@shop.example>\r
            \r

            """.utf8))
    }

    @Test func bundledDataHasTheLists() {
        let data = RulesData.bundled
        #expect(data.version == 2)
        for word in ["invoice", "receipt", "order", "vat", "payment", "statement"] {
            #expect(data.protectedSubjectKeywords.contains(word))
        }
        #expect(data.protectedSenderKeywords.contains("billing"))
        #expect(!data.billingSenders.isEmpty)
    }

    @Test func subjectKeywordsAreWholeWordsInAnyCase() {
        let set = RuleSet.standard
        #expect(set.assess(bulk(from: "news@shop.example", subject: "20% off everything")).suggestion == .considerDeletingFromSource)
        let invoice = set.assess(bulk(from: "news@shop.example", subject: "Your INVOICE #123"))
        #expect(invoice.suggestion == .keep)
        #expect(invoice.protection?.kind == .subjectKeyword)
        #expect(invoice.reasons.first == "Protected: subject contains 'invoice'.")
        #expect(set.assess(bulk(from: "news@shop.example", subject: "VAT receipt")).protection != nil)
        #expect(set.assess(bulk(from: "news@shop.example", subject: "Order confirmed: 2 items")).protection != nil)
        #expect(set.assess(bulk(from: "news@shop.example", subject: "Payments made easy")).protection != nil)
        // Not inside longer words.
        #expect(set.assess(bulk(from: "news@shop.example", subject: "Disorderly conduct, invaded")).protection == nil)
        #expect(set.assess(bulk(from: "news@shop.example", subject: "Statementless prose")).protection == nil)
    }

    @Test func senderKeywordsAndBillingSenders() {
        let set = RuleSet.standard
        let keyword = set.assess(bulk(from: "billing-noreply@shop.example", subject: "Hello"))
        #expect(keyword.protection?.kind == .senderKeyword)
        #expect(keyword.reasons.first == "Protected: sender address contains 'billing'.")
        #expect(set.assess(bulk(from: "receipts+abc@pay.example", subject: "Hello")).protection?.kind == .senderKeyword)
        #expect(set.assess(bulk(from: "border@shop.example", subject: "Hello")).protection == nil)
        let billing = set.assess(bulk(from: "auto-confirm@amazon.co.uk", subject: "Hello"))
        #expect(billing.protection?.kind == .billingSender)
        #expect(billing.reasons.first == "Protected: amazon.co.uk is a known billing sender.")
        // Billing senders match a full address exactly, not the rest of the domain.
        #expect(set.assess(bulk(from: "store-news@amazon.co.uk", subject: "Hello")).protection == nil)
    }

    @Test func userProtectedSendersWinOverOverridesAndNeverShowTheAddress() {
        var set = RuleSet.standard
        set.senderOverrides = [SenderOverride(match: "ana@friends.example", suggestion: .considerDeletingFromSource)]
        set.protectedSenders = ["ana@friends.example", "club.example"]
        let ana = set.assess(bulk(from: "Ana <ana@friends.example>", subject: "Hello"))
        #expect(ana.suggestion == .keep)
        #expect(ana.protection?.kind == .userSender)
        #expect(ana.reasons.first == "Protected: you protect mail from friends.example.")
        #expect(ana.reasons.contains("Protected mail is always kept, so your override does not apply to it."))
        #expect(!ana.reasons.joined().contains("ana@"))
        #expect(set.assess(bulk(from: "news@club.example", subject: "Hello")).protection?.kind == .userSender)
        #expect(set.assess(bulk(from: "news@sub.club.example", subject: "Hello")).protection == nil)
    }

    @Test func protectedSendersNeverReachTheSettingsFile() throws {
        var set = RuleSet.standard
        set.protectedSenders = ["ana@friends.example"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try set.save(to: url)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("friends"))
        #expect(try RuleSet.load(from: url).protectedSenders.isEmpty)
    }

    @Test func aVersionOneDataFileStillReads() throws {
        let old = #"{"version": 1, "noReplyLocalParts": ["noreply"], "listProviderDomains": []}"#
        let data = try JSONDecoder().decode(RulesData.self, from: Data(old.utf8))
        #expect(data.protectedSubjectKeywords.isEmpty && data.billingSenders.isEmpty)
    }
}
