import CryptoKit
import Foundation
import GRDB
import os
import StowCore
import StowRules
import StowSecrets
import StowStore
import StowTestSupport
import Testing
@testable import StowEngine

/// D-521, D-522: "a known billing sender" shows only where the stored result is
/// `pass`. NULL (not read yet), `fail` and `none` show the "Kept" wording, and
/// the message is protected in every case.
@Suite(.serialized) struct StoredBillingLabelTests {
    static let googlePass = "mx.google.com; dkim=pass header.i=@paypal.com; spf=pass (google.com: domain of service@paypal.com designates 192.0.2.1 as permitted sender) smtp.mailfrom=service@paypal.com; dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=paypal.com"
    static let label = "Protected: paypal.com is a known billing sender."
    static let kept = "Kept: from a billing address at paypal.com."

    final class Fixture: @unchecked Sendable {
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        let archive: Archive
        let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "S")
        var settings: URL { location.root.appendingPathComponent("rules.json") }
        private var uid: UInt32 = 0

        init() throws {
            archive = try Archive.open(location, keys: keys)
            try archive.register(account)
        }

        deinit { try? FileManager.default.removeItem(at: location.root) }

        /// A bulk-looking receipt from a listed billing sender, with Gmail's own field saying DMARC passed.
        @discardableResult
        func addReceipt() throws -> StoredMessageID {
            uid += 1
            let text = """
                Authentication-Results: \(StoredBillingLabelTests.googlePass)\r
                From: PayPal <service@paypal.com>\r
                To: sam@example.com\r
                Subject: Hello\r
                List-Unsubscribe: <https://example.org/u>\r
                Precedence: bulk\r
                Message-ID: <p\(uid)@example.org>\r
                \r
                body\r

                """
            let classifier = EngineRules.classifier(try EngineRules.ruleSet(settings: settings, archive: archive, account: account.id))
            let raw = RawMessage(key: RawMessageKey(accountID: account.id, folder: "[Gmail]/All Mail", uidValidity: 1, uid: uid),
                                 internalDate: Date(), size: text.utf8.count, bytes: Data(text.utf8))
            guard case .imported(let id) = try Importer(archive: archive, classifier: classifier).importMessage(raw) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return id
        }

        func setStored(_ value: String?) throws {
            try archive.database.write { db in try db.execute(sql: "UPDATE messages SET sender_dmarc = ?", arguments: [value]) }
        }

        func storedValues() throws -> [String?] {
            try archive.database.read { db in
                try Row.fetchAll(db, sql: "SELECT sender_dmarc FROM messages ORDER BY id").map { $0["sender_dmarc"] as String? }
            }
        }
    }

    /// `stowmail rules report`: the label from the stored result only. The old code
    /// computed it from the header each run, so a message not yet read showed it.
    @Test(arguments: [("pass", true), ("fail", false), ("none", false), (nil, false)] as [(String?, Bool)])
    func rulesReportShowsTheLabelOnlyForAStoredPass(stored: String?, labelled: Bool) throws {
        let f = try Fixture()
        try f.addReceipt()
        try f.setStored(stored)
        let report = try RulesRunner.run(f.archive, settings: f.settings)
        let reasons = report.bySuggestion[.keep]?.topReasons.map(\.reason) ?? []
        #expect(reasons.contains(labelled ? Self.label : Self.kept), "\(String(describing: stored)): \(reasons)")
        #expect(!reasons.contains(labelled ? Self.kept : Self.label), "\(String(describing: stored)): \(reasons)")
        // Protected either way.
        #expect(report.protected[.billingSender] == 1)
        #expect(report.bySuggestion[.considerDeletingFromSource] == nil)
    }

    /// Tidy up counts billing-list mail whose stored result is `pass` as known
    /// billing senders; NULL and the rest are only "on the billing list".
    @Test func tidySummaryCountsKnownBillingSendersFromTheStoredResult() throws {
        let f = try Fixture()
        for _ in 0..<4 { try f.addReceipt() }
        try f.archive.database.write { db in
            try db.execute(sql: "UPDATE messages SET sender_dmarc = CASE id % 4 WHEN 1 THEN 'pass' WHEN 2 THEN 'fail' WHEN 3 THEN 'none' ELSE NULL END")
        }
        let summary = try TidySummary.compute(f.archive, settings: f.settings)
        #expect(summary.protectedByKind[.billingSender] == 4)
        #expect(summary.knownBillingSenders == 1)
        #expect(summary.protectedTotal == 4)
        #expect(summary.suggestions.allSatisfy { $0.messages == 0 })
    }

    /// The daemon's first round reads the result for messages stored before v3,
    /// once per process (D-521), and the label then shows.
    @Test func theFirstRoundBackfillsOlderMessages() async throws {
        let f = try Fixture()
        for _ in 0..<3 { try f.addReceipt() }
        try f.setStored(nil)
        try RecoveryBundle.write(f.keys, archiveID: try f.archive.archiveID(), recoveryKey: RecoveryKey.generate(), to: f.location.root)
        try ArchiveSetup.markConfirmed(f.archive)
        try f.archive.database.close()

        let scheduler = Scheduler(
            openArchive: { try Archive.open(f.location, keys: f.keys) },
            makeSync: { _ in throw CocoaError(.featureUnsupported) },
            power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) },
            restartWhen: { false },
            sleep: { _ in }
        )
        _ = await scheduler.round()
        let check = try Archive.open(f.location, keys: f.keys)
        defer { try? check.database.close() }
        #expect(try await check.database.read { db in
            try String.fetchAll(db, sql: "SELECT sender_dmarc FROM messages ORDER BY id")
        } == ["pass", "pass", "pass"])
    }

    /// A hold from the app stops the backfill before it reads anything; the next
    /// round, with the hold lifted, reads them.
    @Test func aHeldRoundLeavesTheBackfillForLater() async throws {
        let f = try Fixture()
        try f.addReceipt()
        try f.setStored(nil)
        try RecoveryBundle.write(f.keys, archiveID: try f.archive.archiveID(), recoveryKey: RecoveryKey.generate(), to: f.location.root)
        try ArchiveSetup.markConfirmed(f.archive)
        try f.archive.database.close()

        let held = OSAllocatedUnfairLock(initialState: true)
        let scheduler = Scheduler(
            openArchive: { try Archive.open(f.location, keys: f.keys) },
            makeSync: { _ in throw CocoaError(.featureUnsupported) },
            power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) },
            hold: { held.withLock { $0 } ? "The app is moving the archive" : nil },
            restartWhen: { false },
            sleep: { _ in }
        )
        _ = await scheduler.round()
        var check = try Archive.open(f.location, keys: f.keys)
        #expect(try await check.database.read { db in try String?.fetchAll(db, sql: "SELECT sender_dmarc FROM messages") } == [nil])
        try check.database.close()

        held.withLock { $0 = false }
        _ = await scheduler.round()
        check = try Archive.open(f.location, keys: f.keys)
        defer { try? check.database.close() }
        #expect(try await check.database.read { db in try String?.fetchAll(db, sql: "SELECT sender_dmarc FROM messages") } == ["pass"])
    }
}
