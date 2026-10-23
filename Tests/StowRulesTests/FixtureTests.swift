import Foundation
import StowCore
import Testing
@testable import StowRules

private let owner: Set<String> = ["sam@example.com"]

private let fixtureDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/eml")

private struct Manifest: Decodable {
    struct Entry: Decodable { var file: String; var personal: Bool }
    var fixtures: [Entry]
}

private func headers(_ file: String) throws -> MessageHeaders {
    try HeaderParser().parseHeaders(Data(contentsOf: fixtureDir.appendingPathComponent(file)))
}

private func fired(_ file: String, _ id: SignalID) throws -> Bool {
    let s = Signals.signal(id)
    return s.evaluate(try headers(file), context: SignalContext(ownAddresses: owner)).fired
}

@Test func listUnsubscribeFixture() throws {
    #expect(try fired("18-list-unsubscribe.eml", .listUnsubscribe))
    #expect(try !fired("01-plain-text.eml", .listUnsubscribe))
}

@Test func precedenceFixture() throws {
    #expect(try fired("19-precedence-bulk.eml", .precedenceBulk))
    #expect(try !fired("01-plain-text.eml", .precedenceBulk))
}

@Test func noReplyFixture() throws {
    #expect(try fired("20-noreply-sender.eml", .senderNoReply))
    #expect(try !fired("01-plain-text.eml", .senderNoReply))
}

@Test func replyToFixture() throws {
    #expect(try fired("21-reply-to-differs.eml", .replyToDiffers))
    #expect(try !fired("01-plain-text.eml", .replyToDiffers))
}

@Test func recipientCountFixture() throws {
    #expect(try fired("22-sixty-recipients.eml", .recipientCount))
    #expect(try !fired("01-plain-text.eml", .recipientCount))
}

@Test func bccOnlyFixture() throws {
    #expect(try fired("23-bcc-only.eml", .userNotInTo))
    #expect(try !fired("01-plain-text.eml", .userNotInTo))
}

@Test func listProviderFixture() throws {
    #expect(try fired("25-newsletter-combined.eml", .senderListProvider))
    #expect(try !fired("01-plain-text.eml", .senderListProvider))
}

@Test func combinedNewsletterFixture() throws {
    let a = RuleSet.standard.assess(try headers("25-newsletter-combined.eml"), ownAddresses: owner)
    #expect(a.suggestion == .considerDeletingFromSource)
}

@Test func singleSignalFixturesAreNotDeleteSuggestions() throws {
    for f in ["18-list-unsubscribe.eml", "19-precedence-bulk.eml", "20-noreply-sender.eml",
              "21-reply-to-differs.eml", "22-sixty-recipients.eml", "23-bcc-only.eml"] {
        let a = RuleSet.standard.assess(try headers(f), ownAddresses: owner)
        #expect(a.suggestion != .considerDeletingFromSource, "\(f)")
        #expect(!a.reasons.isEmpty)
    }
}

@Test func personalFixturesAreKept() throws {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtureDir.appendingPathComponent("manifest.json")))
    let personal = manifest.fixtures.filter(\.personal)
    #expect(personal.count >= 10)
    for entry in personal {
        let a = RuleSet.standard.assess(try headers(entry.file), ownAddresses: owner)
        #expect(a.suggestion == .keep, "\(entry.file) scored \(a.score)")
    }
}
