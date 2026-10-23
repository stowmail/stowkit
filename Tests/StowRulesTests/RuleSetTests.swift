import Foundation
import StowCore
import Testing
@testable import StowRules

private func addr(_ a: String) -> EmailAddress { EmailAddress(address: a) }
private let me: Set<String> = ["sam@example.com"]

private let newsletter = MessageHeaders(
    from: [addr("noreply@deals.example.com")], to: [addr("sam@example.com")],
    listUnsubscribe: "<https://x.example/u>", precedence: "bulk")
private let friend = MessageHeaders(from: [addr("pat@friend.example")], to: [addr("sam@example.com")])

@Test func personalMailIsKept() {
    let a = RuleSet.standard.assess(friend, ownAddresses: me)
    #expect(a.suggestion == .keep)
    #expect(a.score == 0)
    #expect(!a.reasons.isEmpty)
}

@Test func twoStrongSignalsAllowConsideringDeletion() {
    let a = RuleSet.standard.assess(newsletter, ownAddresses: me)
    #expect(a.suggestion == .considerDeletingFromSource)
    #expect(a.reasons.count >= 3)
}

@Test func oneStrongSignalOnlyDeprioritises() {
    var h = friend
    h.listUnsubscribe = "<https://x.example/u>"
    #expect(RuleSet.standard.assess(h, ownAddresses: me).suggestion == .deprioritise)
}

@Test func manyWeakSignalsNeverReachDeletion() {
    var set = RuleSet.standard
    set.considerDeletingAt = 3
    let many = (0..<30).map { addr("p\($0)@x.example") }
    let h = MessageHeaders(from: [addr("noreply@x.example")], replyTo: [addr("r@y.example")],
                           to: many, cc: [addr("sam@example.com")])
    let a = set.assess(h, ownAddresses: me)
    #expect(a.score >= 3)
    #expect(a.suggestion == .deprioritise)
    #expect(a.reasons.contains { $0.contains("fewer than 2 strong") })
}

@Test func disablingARuleRemovesItsEffect() {
    var set = RuleSet.standard
    set.setEnabled(.precedenceBulk, false)
    set.setEnabled(.listUnsubscribe, false)
    let a = set.assess(newsletter, ownAddresses: me)
    #expect(a.suggestion == .keep)
    #expect(a.outcomes.first { $0.signal == .listUnsubscribe }?.fired == true)
    #expect(a.outcomes.first { $0.signal == .listUnsubscribe }?.enabled == false)
}

@Test func senderOverrideWinsByAddressAndDomain() {
    var set = RuleSet.standard
    set.senderOverrides = [SenderOverride(match: "NoReply@deals.example.com", suggestion: .keep)]
    let a = set.assess(newsletter, ownAddresses: me)
    #expect(a.suggestion == .keep)
    #expect(a.overriddenBy != nil)
    #expect(a.score == RuleSet.standard.assess(newsletter, ownAddresses: me).score)

    set.senderOverrides = [SenderOverride(match: "deals.example.com", suggestion: .deprioritise)]
    #expect(set.assess(newsletter, ownAddresses: me).suggestion == .deprioritise)
    set.senderOverrides = [SenderOverride(match: "example.com", suggestion: .keep)]
    #expect(set.assess(newsletter, ownAddresses: me).suggestion == .considerDeletingFromSource)
}

@Test func settingsRoundTripAndPermissions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-rules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("rules.json")
    var set = RuleSet.standard
    set.setEnabled(.recipientCount, false)
    set.senderOverrides = [SenderOverride(match: "a@b.example", suggestion: .keep)]
    try set.save(to: url)
    #expect(try RuleSet.load(from: url) == set)
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

@Test func missingFileGivesStandardAndBadFilesAreErrors() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-rules-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try RuleSet.load(from: dir.appendingPathComponent("none.json")) == .standard)

    let bad = dir.appendingPathComponent("bad.json")
    try Data("{nope".utf8).write(to: bad)
    #expect(throws: RuleSetError.self) { try RuleSet.load(from: bad) }

    var future = RuleSet.standard
    future.version = 99
    let f = dir.appendingPathComponent("future.json")
    try future.save(to: f)
    #expect(throws: RuleSetError.self) { try RuleSet.load(from: f) }
}

@Test func bundledDataLoads() {
    #expect(!RulesData.bundled.listProviderDomains.isEmpty)
    #expect(!RulesData.bundled.noReplyLocalParts.isEmpty)
}
