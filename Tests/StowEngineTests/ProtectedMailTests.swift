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

/// Protected mail in the archive (UI-10, D-407): stored with the rules result,
/// left out of removal by rule or suggestion, and kept through a rules re-run.
@Suite(.serialized) struct ProtectedMailTests {
    final class Fixture: @unchecked Sendable {
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        let archive: Archive
        let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "S")
        var settings: URL { location.root.appendingPathComponent("rules.json") }
        private var uid: UInt32 = 0
        private(set) var ids: [String: StoredMessageID] = [:]

        init() throws {
            archive = try Archive.open(location, keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
            try archive.register(account)
            // Two strong signals each: consider deleting, unless protected.
            try add("invoice", from: "news@shop.example", subject: "Your invoice for October")
            try add("offer", from: "news@shop.example", subject: "20% off this weekend")
            try add("club", from: "hello@club.example", subject: "This month at the club")
        }

        deinit { try? FileManager.default.removeItem(at: location.root) }

        func add(_ name: String, from: String, subject: String) throws {
            uid += 1
            let text = """
                From: \(from)\r
                To: sam@example.com\r
                Subject: \(subject)\r
                List-Unsubscribe: <https://example.org/u>\r
                Precedence: bulk\r
                Message-ID: <\(name)@example.org>\r
                \r
                body\r

                """
            let classifier = EngineRules.classifier(try EngineRules.ruleSet(settings: settings, archive: archive, account: account.id))
            let raw = RawMessage(key: RawMessageKey(accountID: account.id, folder: "[Gmail]/All Mail", uidValidity: 1, uid: uid),
                                 internalDate: Date(), size: text.utf8.count, bytes: Data(text.utf8))
            guard case .imported(let id) = try Importer(archive: archive, classifier: classifier).importMessage(raw) else {
                throw CocoaError(.fileWriteUnknown)
            }
            ids[name] = id
        }

        func stored(_ name: String) throws -> (suggestion: String, signals: String) {
            try archive.database.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT rule_suggestion, rule_signals FROM messages WHERE id = ?", arguments: [self.ids[name]!])!
                return (row["rule_suggestion"], row["rule_signals"])
            }
        }
    }

    @Test func protectedMailIsStoredAsKeepAndLeftOutOfRuleRemovals() throws {
        let f = try Fixture()
        #expect(try f.stored("invoice").suggestion == "keep")
        #expect(try f.stored("invoice").signals.split(separator: ",").contains("protected"))
        #expect(try f.stored("offer").suggestion == "consider_deleting")

        let removal = ArchiveRemoval(archive: f.archive)
        let byRule = try removal.plan(.signal("listUnsubscribe"))
        #expect(byRule.messageIDs == [f.ids["offer"]!, f.ids["club"]!])
        #expect(byRule.protectedLeftOut == 1)
        #expect(try removal.plan(.suggestion(.keep)).messageIDs.isEmpty)
        // `--rule protected` is not a signal: the CLI refuses it, and the marker selects nothing here either.
        #expect(try removal.plan(.signal("protected")).messageIDs.isEmpty)
        // Naming the sender yourself includes it, and says so.
        let bySender = try removal.plan(.sender("shop.example"))
        #expect(bySender.messageIDs.count == 2 && bySender.protectedIncluded == 1 && bySender.protectedLeftOut == 0)
    }

    @Test func aUserProtectedSenderSurvivesARulesRerun() throws {
        let f = try Fixture()
        #expect(try f.stored("club").suggestion == "consider_deleting")
        #expect(try ProtectedSenders(archive: f.archive).add("Club.Example"))
        #expect(try !ProtectedSenders(archive: f.archive).add("club.example"))
        #expect(try ProtectedSenders(archive: f.archive).list() == ["club.example"])
        // Not in the settings file: the archive holds it (D-041).
        let file = (try? Data(contentsOf: f.settings)) ?? Data()
        #expect(!String(decoding: file, as: UTF8.self).contains("club"))

        let one = try RulesRunner.run(f.archive, settings: f.settings, sender: "club.example")
        #expect(one.messages == 1 && one.protected[.userSender] == 1)
        #expect(try f.stored("club").suggestion == "keep")

        let all = try RulesRunner.run(f.archive, settings: f.settings)
        #expect(all.messages == 3)
        #expect(all.protected == [.userSender: 1, .subjectKeyword: 1])
        #expect(try f.stored("club").suggestion == "keep")
        #expect(try f.stored("invoice").suggestion == "keep")
        #expect(try ArchiveRemoval(archive: f.archive).plan(.suggestion(.considerDeleting)).messageIDs == [f.ids["offer"]!])

        #expect(try ProtectedSenders(archive: f.archive).remove("club.example"))
        _ = try RulesRunner.run(f.archive, settings: f.settings, sender: "club.example")
        #expect(try f.stored("club").suggestion == "consider_deleting")
    }
}
