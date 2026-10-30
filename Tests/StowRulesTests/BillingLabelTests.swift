import Foundation
import StowCore
import Testing
@testable import StowRules

/// D-486 (3), D-521: "a known billing sender" only when the provider's own topmost
/// Authentication-Results says DMARC passed for the From domain. Protected either way.
struct BillingLabelTests {
    static func message(_ authentication: [String], above: [String] = [], from: String = "PayPal <service@paypal.com>") -> MessageHeaders {
        let extra = above.map { "\($0)\r\n" }.joined() + authentication.map { "Authentication-Results: \($0)\r\n" }.joined()
        return HeaderParser().parseHeaders(Data("""
            \(extra)ARC-Authentication-Results: i=1; mx.google.com; dmarc=pass header.from=paypal.com\r
            From: \(from)\r
            To: sam@example.com\r
            Subject: Hello\r
            List-Unsubscribe: <https://x.example/u>\r
            Precedence: bulk\r
            \r

            """.utf8))
    }

    static let googlePass = "mx.google.com; dkim=pass header.i=@paypal.com header.s=pp-dkim1; spf=pass (google.com: domain of service@paypal.com designates 1.2.3.4 as permitted sender) smtp.mailfrom=service@paypal.com; dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=paypal.com"
    static let microsoftPass = "spf=pass (sender IP is 1.2.3.4) smtp.mailfrom=paypal.com; dkim=pass (signature was verified) header.d=paypal.com;dmarc=pass action=none header.from=paypal.com;compauth=pass reason=100"
    /// Outlook.com's form (seen 2026-10-30): authserv-id and version, ";" without a space, compauth after DMARC.
    static let outlookPass = "mx.microsoft.com 1; spf=pass (sender IP is 192.0.2.1) smtp.mailfrom=paypal.com; dkim=pass (signature was verified) header.d=paypal.com;dmarc=pass action=none header.from=paypal.com;compauth=pass reason=100"
    /// The same, folded as a server writes it (unfolded by `HeaderParser`).
    static let outlookPassFolded = "mx.microsoft.com 1; spf=pass (sender IP is\r\n 192.0.2.1) smtp.mailfrom=paypal.com; dkim=pass (signature was\r\n\tverified) header.d=paypal.com;dmarc=pass action=none\r\n header.from=paypal.com;\r\n compauth=pass reason=100"

    struct Case: Sendable, CustomStringConvertible {
        var name: String
        var provider: Provider
        var headers: [String]
        var above: [String] = []
        var expected: SenderDMARC
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "(a) Gmail, provider says pass", provider: .gmail, headers: [googlePass], expected: .pass),
        Case(name: "(a) Microsoft, provider says pass", provider: .microsoft, headers: [microsoftPass], expected: .pass),
        Case(name: "(b) provider says fail", provider: .gmail,
             headers: [googlePass.replacingOccurrences(of: "dmarc=pass", with: "dmarc=fail")], expected: .fail),
        Case(name: "(b) pass for another domain", provider: .gmail,
             headers: [googlePass.replacingOccurrences(of: "header.from=paypal.com", with: "header.from=paypa1.com")], expected: .fail),
        Case(name: "(c) no header", provider: .gmail, headers: [], expected: .none),
        Case(name: "(d) forged pass below the provider's fail", provider: .gmail,
             headers: [googlePass.replacingOccurrences(of: "dmarc=pass", with: "dmarc=fail"), googlePass], expected: .fail),
        Case(name: "(e) forged header first, iCloud account", provider: .icloud, headers: [googlePass], expected: .none),
        Case(name: "(e) another authserv-id first, Gmail account", provider: .gmail,
             headers: [googlePass.replacingOccurrences(of: "mx.google.com;", with: "mx.evil.example;"), googlePass], expected: .none),
        Case(name: "(e) Google's form on a Microsoft account", provider: .microsoft, headers: [googlePass], expected: .none),
        Case(name: "comment hiding a pass", provider: .gmail,
             headers: ["mx.google.com; dmarc=fail (dmarc=pass header.from=paypal.com) header.from=paypal.com"], expected: .fail),
        Case(name: "Outlook.com: authserv-id and version, no space after ;, compauth", provider: .microsoft,
             headers: [outlookPass], expected: .pass),
        Case(name: "Outlook.com, folded", provider: .microsoft, headers: [outlookPassFolded], expected: .pass),
        Case(name: "Outlook.com, unknown properties before DMARC", provider: .microsoft,
             headers: ["mx.microsoft.com 1; arc=none;x-unknown=pass reason=1; compauth=pass reason=100;dmarc=pass action=none header.from=paypal.com"],
             expected: .pass),
        Case(name: "Outlook.com, bestguesspass is not a pass", provider: .microsoft,
             headers: [outlookPass.replacingOccurrences(of: "dmarc=pass", with: "dmarc=bestguesspass")], expected: .fail),
        Case(name: "Outlook.com, authserv-id followed by more than a version", provider: .microsoft,
             headers: [outlookPass.replacingOccurrences(of: "mx.microsoft.com 1;", with: "mx.microsoft.com.evil.example 1;")], expected: .none),
        Case(name: "Outlook.com's form on a Gmail account", provider: .gmail, headers: [outlookPass], expected: .none),
        Case(name: "ARC-Authentication-Results above the provider's field is ignored", provider: .microsoft,
             headers: [outlookPass.replacingOccurrences(of: "dmarc=pass", with: "dmarc=fail")],
             above: ["ARC-Authentication-Results: i=1; \(outlookPass)"], expected: .fail),
        Case(name: "ARC-Authentication-Results alone is ignored", provider: .microsoft,
             headers: [], above: ["ARC-Authentication-Results: i=1; \(outlookPass)"], expected: .none),
    ]

    @Test(arguments: cases)
    func theLabelNeedsTheProvidersPass(_ test: Case) {
        let headers = Self.message(test.headers, above: test.above)
        let dmarc = ProviderAuthentication.dmarc(headers, provider: test.provider)
        #expect(dmarc == test.expected)
        let assessment = RuleSet.standard.assess(headers, senderDMARC: dmarc)
        // Protected in every case.
        #expect(assessment.suggestion == .keep)
        #expect(assessment.protection?.kind == .billingSender)
        let reason = assessment.reasons.first ?? ""
        if test.expected == .pass {
            #expect(reason == "Protected: paypal.com is a known billing sender.")
        } else {
            #expect(reason == "Kept: from a billing address at paypal.com.")
        }
    }
}
