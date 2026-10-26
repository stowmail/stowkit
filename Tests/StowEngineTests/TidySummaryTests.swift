import CryptoKit
import Foundation
import GRDB
import StowCore
import StowRules
import StowSecrets
import StowStore
import StowTestSupport
import Testing
@testable import StowEngine

/// R13: Tidy up's summary matches what removal would select, names no
/// address in its reasons, and splits out what the user changed at the provider.
@Suite(.serialized) struct TidySummaryTests {
    final class Fixture: @unchecked Sendable {
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        let archive: Archive
        let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "S")
        var settings: URL { location.root.appendingPathComponent("rules.json") }
        private var uid: UInt32 = 0
        private(set) var ids: [StoredMessageID] = []

        init() throws {
            archive = try Archive.open(location, keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
            try archive.register(account)
        }

        deinit { try? FileManager.default.removeItem(at: location.root) }

        /// `bulk`: two strong signals (consider deleting); otherwise one (deprioritise) or none.
        @discardableResult
        func add(from: String, name: String = "Shop", subject: String, signals: Int, daysAgo: Double = 1) throws -> StoredMessageID {
            uid += 1
            var headers = "From: \(name) <\(from)>\r\nTo: sam@example.com\r\nSubject: \(subject)\r\nMessage-ID: <m\(uid)@example.org>\r\n"
            if signals >= 1 { headers += "List-Unsubscribe: <https://example.org/u>\r\n" }
            if signals >= 2 { headers += "Precedence: bulk\r\n" }
            let text = headers + "\r\nbody \(uid)\r\n"
            let classifier = EngineRules.classifier(try EngineRules.ruleSet(settings: settings, archive: archive, account: account.id))
            let raw = RawMessage(key: RawMessageKey(accountID: account.id, folder: "[Gmail]/All Mail", uidValidity: 1, uid: uid),
                                 internalDate: Date().addingTimeInterval(-daysAgo * 86_400), size: text.utf8.count, bytes: Data(text.utf8))
            guard case .imported(let id) = try Importer(archive: archive, classifier: classifier).importMessage(raw) else {
                throw CocoaError(.fileWriteUnknown)
            }
            ids.append(id)
            return id
        }
    }

    @Test func groupsMatchRemovalPlansAndNameNoAddressInReasons() throws {
        let f = try Fixture()
        for n in 0..<3 { try f.add(from: "news@shop.example", subject: "Offer \(n)", signals: 2, daysAgo: Double(n)) }
        try f.add(from: "news@shop.example", subject: "Your invoice for October", signals: 2)  // protected by subject
        try f.add(from: "hello@club.example", name: "Club", subject: "This month", signals: 2)
        try f.add(from: "digest@forum.example", subject: "Weekly digest", signals: 1)
        try f.add(from: "jo@friends.example", subject: "Lunch?", signals: 0)

        let summary = try TidySummary.compute(f.archive, settings: f.settings)
        let removal = ArchiveRemoval(archive: f.archive)
        for group in summary.suggestions {
            let plan = try removal.plan(.suggestion(group.suggestion))
            #expect(group.messages == plan.messageIDs.count)
            #expect(group.bytes == plan.bytes)
            #expect(group.senderDomains == plan.senderDomains)
        }
        let consider = try #require(summary.suggestions.first { $0.suggestion == .considerDeleting })
        #expect(consider.senders.map(\.address) == ["news@shop.example", "hello@club.example"])
        let shop = consider.senders[0]
        #expect(shop.messages == 3 && shop.protectedLeftOut == 1 && shop.name == "Shop")
        #expect(shop.newest.timeIntervalSinceNow > -86_400 - 60)
        #expect(shop.reasons.contains("Has an unsubscribe header") && shop.reasons.contains("Marked as bulk or list mail"))
        for sender in summary.suggestions.flatMap(\.senders) {
            #expect(!sender.reasons.contains { $0.contains("@") })
        }
        #expect(summary.suggestions.first { $0.suggestion == .deprioritise }?.senders.map(\.address) == ["digest@forum.example"])
        #expect(summary.protectedTotal == 1 && summary.protectedByKind[.subjectKeyword] == 1)
        #expect(summary.messages == 7)
    }

    @Test func theUsersOwnChoiceIsGivenAsAReason() throws {
        let f = try Fixture()
        try RuleOverrides(archive: f.archive).set("forum.example", .considerDeleting)
        try f.add(from: "digest@forum.example", subject: "Weekly digest", signals: 0)
        let summary = try TidySummary.compute(f.archive, settings: f.settings)
        let sender = try #require(summary.suggestions.first { $0.suggestion == .considerDeleting }?.senders.first)
        #expect(sender.reasons.first == "Your choice for forum.example.")
    }

    @Test func protectedByKindAndUserProtectedSenders() throws {
        let f = try Fixture()
        try ProtectedSenders(archive: f.archive).add("friends.example")
        try f.add(from: "jo@friends.example", subject: "Club news", signals: 2)
        try f.add(from: "billing@utility.example", subject: "Statement ready", signals: 2)
        let summary = try TidySummary.compute(f.archive, settings: f.settings)
        #expect(summary.protectedTotal == 2)
        #expect(summary.protectedByKind[.userSender] == 1)
        #expect(summary.protectedByKind[.senderKeyword] == 1)
        #expect(summary.suggestions.allSatisfy { $0.messages == 0 })
    }

    @Test func sourceStatesWithRetentionAndProtection() async throws {
        let f = try Fixture()
        let spam = try f.add(from: "a@x.example", subject: "Invoice overdue", signals: 0)  // protected, then spam
        let oldTrash = try f.add(from: "b@x.example", subject: "Old", signals: 0, daysAgo: 800)
        let newTrash = try f.add(from: "c@x.example", subject: "New", signals: 0, daysAgo: 10)
        let gone = try f.add(from: "d@x.example", subject: "Gone", signals: 0, daysAgo: 20)
        try await ArchiveSyncStore(archive: f.archive).setSourceStates(f.account.id, [spam: .spam, oldTrash: .trashed,
                                                                                  newTrash: .trashed, gone: .gone], at: Date())
        try StowStore.Coverage.setRetention(f.archive, account: f.account.id, months: 12)
        let summary = try TidySummary.compute(f.archive, settings: f.settings)
        let byState = Dictionary(uniqueKeysWithValues: summary.sourceStates.map { ($0.state, $0) })
        #expect(byState[.spam]?.messages == 1 && byState[.spam]?.protectedIncluded == 1 && byState[.spam]?.olderThanRetention == 0)
        #expect(byState[.trashed]?.messages == 2 && byState[.trashed]?.olderThanRetention == 1)
        #expect(byState[.gone]?.messages == 1 && byState[.gone]?.olderThanRetention == 0)
        let removal = ArchiveRemoval(archive: f.archive)
        for state in [SourceState.spam, .trashed, .gone] {
            let plan = try removal.plan(.sourceState(state))
            #expect(byState[state]?.messages == plan.messageIDs.count && byState[state]?.bytes == plan.bytes)
            #expect(byState[state]?.protectedIncluded == plan.protectedIncluded)
        }
        // One account's scope.
        let other = try TidySummary.compute(f.archive, account: AccountID(rawValue: "nobody"), settings: f.settings)
        #expect(other.messages == 0 && other.sourceStates.allSatisfy { $0.messages == 0 })
    }

    /// The part of the summary that grows with protected mail: saying why each one is
    /// protected. The benchmark archive has almost none, so time 30,000 here (R13's budget is 1 s).
    @Test func whyProtectedStaysFastForThirtyThousand() throws {
        var rules = RuleSet.standard
        rules.protectedSenders = ["friends.example"]
        let senders = ["billing@utility.example", "auto-confirm@amazon.co.uk", "jo@friends.example", "news@shop.example"]
        let started = ContinuousClock.now
        var found = 0
        for n in 0..<30_000 {
            let headers = MessageHeaders(from: [EmailAddress(name: "Sender", address: senders[n % senders.count])],
                                         subject: "Your order \(n) receipt")
            if rules.protection(headers) != nil { found += 1 }
        }
        let elapsed = ContinuousClock.now - started
        #expect(found == 30_000)
        #expect(elapsed < .milliseconds(500), "\(elapsed)")
    }
}
