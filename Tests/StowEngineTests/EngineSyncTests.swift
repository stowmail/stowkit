import Foundation
import GRDB
import StowCore
import StowEngine
import StowSearch
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

/// Phase 2 end to end: sync writes straight into the encrypted archive
/// (steps 3, 4, 6, 7), against the fake server.
@Suite(.serialized) struct EngineSyncTests {
    /// Steps 3 and 4: everything downloads, byte for byte, personal mail before bulk mail.
    @Test func firstSyncArchivesEverythingPersonalMailFirst() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: microsoftServer(fixtures))
        defer { harness.cleanUp() }

        let report = try await harness.run()
        #expect(report.outcome == .complete)
        #expect(report.messagesWritten == fixtures.count)
        #expect(report.remaining == QueueTotals())
        #expect(Set(try harness.storedBytes()) == Set(fixtures.map(\.bytes)))
        #expect(readOnlyViolations(harness.server.commandLog).isEmpty)

        // Import order is download order: the rules' bulk mail came last (D-028).
        let order = try await harness.archive.database.read { db in
            try String.fetchAll(db, sql: "SELECT coalesce(rule_suggestion, '') FROM messages ORDER BY id")
        }
        let firstBulk = try #require(order.firstIndex { $0 != "keep" })
        #expect(order[firstBulk...].allSatisfy { $0 != "keep" })
        #expect(order.last == "consider_deleting")
        #expect(try harness.count("messages", "rule_suggestion = 'deprioritise'") == 2)
        // Only the listed header fields were fetched to decide that, never full headers.
        #expect(harness.server.commandLog.contains { $0.uppercased().contains("BODY.PEEK[HEADER.FIELDS (") })

        // Flags came with the download, and the folder's first sync is complete.
        // IMAP copies carry no labels: only Gmail has them, through the API (D-601).
        #expect(try harness.count("message_folders", "flags = '\\Seen'") == 1)
        #expect(try harness.count("folders", "kind = 'label'") == 0)
        let state = try await ArchiveSyncStore(archive: harness.archive).folderState(harness.account.id, folder: inbox)
        #expect(state?.firstSyncCompletedAt != nil)
        let coverage = try Coverage.compute(harness.archive, account: harness.account.id).coverageDate
        #expect(coverage != nil)
        // Status works the date out afresh, so a stale stored value never shows.
        try await harness.archive.database.write { db in
            try db.execute(sql: "UPDATE accounts SET coverage_date = 0")
        }
        #expect(try ArchiveStatus.collect(harness.archive).first?.coverageDate == coverage)
        #expect(try ArchiveVerifier(archive: harness.archive).run().isClean)

        // A second run downloads nothing.
        let fetches = harness.server.bodyFetchCount
        #expect(try await harness.run().messagesWritten == 0)
        #expect(harness.server.bodyFetchCount == fetches)
    }

    /// QA: kill the daemon mid-sync repeatedly; the final counts are still exact.
    @Test func killingMidSyncRepeatedlyLeavesExactCounts() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: microsoftServer(fixtures))
        defer { harness.cleanUp() }
        let store = ArchiveSyncStore(archive: harness.archive)
        for kill in [2, 5, 3] {
            let syncer = AccountSyncer(
                account: harness.account,
                openSession: try #require(try harness.sync.syncer(for: harness.account) as? AccountSyncer).openSessionForTests,
                sink: KillingSink(store, killOnWrite: kill),
                state: store,
                budget: ByteBudget(limit: nil, fileURL: nil),
                sleep: { _ in }
            )
            await #expect(throws: CocoaError.self) {
                _ = try await syncer.run(SyncOptions(batches: BatchPlanner(maxMessages: 3)))
            }
        }
        let report = try await harness.run()
        #expect(report.outcome == .complete)
        #expect(try harness.count("messages") == fixtures.count)
        #expect(try harness.count("message_folders", "uid IS NOT NULL") == fixtures.count)
        #expect(try harness.count("download_queue") == 0)
        #expect(Set(try harness.storedBytes()) == Set(fixtures.map(\.bytes)))
        #expect(try ArchiveVerifier(archive: harness.archive).run().isClean)
    }

    /// QA: incremental sync picks up a newly received message within one cycle.
    @Test func newMailArrivesInTheNextRun() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: microsoftServer(fixtures))
        defer { harness.cleanUp() }
        _ = try await harness.run()
        let fresh = Data("From: new@example.org\r\nTo: sam@example.com\r\nSubject: Fresh\r\nMessage-ID: <fresh@example.org>\r\n\r\nNew today.\r\n".utf8)
        harness.server.mutate(inbox) { $0.messages.append(.init(uid: 900, bytes: fresh)) }
        let report = try await harness.run(SyncOptions(checkChanges: .quick))
        #expect(report.messagesWritten == 1)
        #expect(report.queued == 1)
        #expect(try harness.storedBytes().contains(fresh))
    }

    /// D-038: with CONDSTORE, a quick check asks only for what changed.
    @Test func quickCheckUsesChangedSince() async throws {
        let fixtures = try TestFixtures.small()
        let server = microsoftServer(fixtures, condstore: true)
        let harness = try await EngineHarness(server: server)
        defer { harness.cleanUp() }
        _ = try await harness.run() // full check: records HIGHESTMODSEQ
        server.mutate(inbox) { box in
            box.messages[4].flags = ["\\Seen"]
            box.messages[4].modSeq = 60
        }
        let report = try await harness.run(SyncOptions(checkChanges: .quick))
        #expect(report.flagsUpdated == 1)
        #expect(server.commandLog.contains { $0.contains("CHANGEDSINCE 1") })
        #expect(try harness.count("message_folders", "flags = '\\Seen'") == 2)
        // Nothing changed since: a quick check sends no FETCH at all.
        let before = server.commandLog.count
        _ = try await harness.run(SyncOptions(checkChanges: .quick))
        #expect(!server.commandLog[before...].contains { $0.contains("CHANGEDSINCE") })
    }

    /// Step 7 for Microsoft: moves between folders, Deleted Items, Junk and real deletions.
    @Test func microsoftMovesAreFollowedAndDeletionsKept() async throws {
        let fixtures = try TestFixtures.small()
        func message(_ uid: UInt32, _ index: Int) -> FakeIMAPServer.Message { .init(uid: uid, bytes: fixtures[index].bytes) }
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "INBOX", attributes: [], uidValidity: 11, messages: (1...6).map { message(UInt32($0), $0) }),
            .init(name: "Archive", attributes: [], uidValidity: 12, messages: []),
            .init(name: "Deleted Items", attributes: ["\\Trash"], uidValidity: 13, messages: []),
            .init(name: "Junk Email", attributes: ["\\Junk"], uidValidity: 14, messages: []),
        ])
        server.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR"]
        let harness = try await EngineHarness(server: server, provider: .microsoft)
        defer { harness.cleanUp() }
        _ = try await harness.run()
        #expect(try harness.count("messages") == 6)

        // 1 filed in Archive, 2 deleted to Deleted Items, 3 marked as junk, 4 deleted for good.
        server.mutate("INBOX") { $0.messages.removeAll { [1, 2, 3, 4].contains($0.uid) } }
        server.mutate("Archive") { $0.messages = [message(1, 1)] }
        server.mutate("Deleted Items") { $0.messages = [message(1, 2)] }
        server.mutate("Junk Email") { $0.messages = [message(1, 3)] }

        let report = try await harness.run()
        // The moved copies are recognised by their bytes: nothing is stored twice.
        #expect(try harness.count("messages") == 6)
        #expect(report.sourceChanges == [.spam: 1, .gone: 1])
        #expect(try harness.count("messages", "source_state = 'present'") == 3)
        #expect(try harness.count("messages", "source_state = 'trashed'") == 1)
        #expect(try harness.count("messages", "source_state = 'spam'") == 1)
        #expect(try harness.count("messages", "source_state = 'gone'") == 1)
        #expect(readOnlyViolations(server.commandLog).isEmpty)
        // Junk was looked into for Message-IDs only.
        #expect(server.commandLog.contains { $0.uppercased().contains("HEADER.FIELDS (\"MESSAGE-ID\")") })
    }

    /// Step 6 (D-038): after a UIDVALIDITY change every message looks new. With
    /// no permanent ID to go by (Gmail's went with its IMAP path, D-601), each
    /// is downloaded again, recognised by its bytes and linked to the copy
    /// already archived: nothing is stored twice.
    @Test func uidValidityChangeRelinksWithoutStoringTwice() async throws {
        let fixtures = try TestFixtures.small()
        let server = microsoftServer(fixtures)
        let harness = try await EngineHarness(server: server)
        defer { harness.cleanUp() }
        _ = try await harness.run()
        let fetches = server.bodyFetchCount
        server.mutate(inbox) { box in
            box.uidValidity = 70
            for index in box.messages.indices { box.messages[index].uid += 1000 }
        }
        let report = try await harness.run()
        #expect(report.uidValidityResets == 1)
        #expect(server.bodyFetchCount > fetches)
        #expect(try harness.count("messages") == fixtures.count)
        #expect(try harness.count("message_folders", "uid_validity = 70 AND removed_from_server_at IS NULL") == fixtures.count)
        #expect(try harness.count("message_folders", "uid_validity != 70 AND removed_from_server_at IS NULL") == 0)
        #expect(try harness.count("messages", "source_state = 'present'") == fixtures.count)
        #expect(try harness.count("sync_events", "kind = 'uidvalidity_changed'") == 1)
        #expect(Set(try harness.storedBytes()) == Set(fixtures.map(\.bytes)))
    }

    /// D-020, D-033: removed mail is not downloaded again; restored mail is.
    @Test func removedMailStaysRemovedUntilRestored() async throws {
        let fixtures = try TestFixtures.small()
        let server = microsoftServer(fixtures)
        let harness = try await EngineHarness(server: server)
        defer { harness.cleanUp() }
        _ = try await harness.run()
        let removal = ArchiveRemoval(archive: harness.archive)
        let plan = try removal.plan(.suggestion(.considerDeleting))
        #expect(plan.messageIDs.count == 1)
        _ = try removal.remove(plan.messageIDs, reason: "suggestion:consider_deleting")

        // Its copy at the same place is not even downloaded again.
        let fetches = server.bodyFetchCount
        _ = try await harness.run()
        #expect(server.bodyFetchCount == fetches)
        #expect(try harness.count("messages") == fixtures.count - 1)

        // After a UIDVALIDITY change makes every message look new, it is
        // downloaded (there is no permanent ID to go by) but recognised by its
        // bytes and still kept out.
        server.mutate(inbox) { box in
            box.uidValidity = 71
            for index in box.messages.indices { box.messages[index].uid += 2000 }
        }
        _ = try await harness.run()
        #expect(try harness.count("messages") == fixtures.count - 1)
        #expect(try harness.count("tombstones") == 1)

        #expect(try removal.requestRestore(try removal.tombstones().map(\.id)) == (1, 0))
        let report = try await harness.run()
        #expect(report.messagesWritten == 1)
        #expect(try harness.count("messages") == fixtures.count)
        #expect(try harness.count("tombstones") == 0)
    }
}

@Suite(.serialized) struct FolderReportTests {
    /// `stowmail status --folders`: Stow's numbers add up to the server's own count.
    @Test func folderCountsAddUpToTheServers() async throws {
        let fixtures = try TestFixtures.small()
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "INBOX", attributes: [], uidValidity: 11, messages: (1...6).map { .init(uid: UInt32($0), bytes: fixtures[$0].bytes) }),
            .init(name: "Sent Items", attributes: ["\\Sent"], uidValidity: 12, messages: (1...3).map { .init(uid: UInt32($0), bytes: fixtures[$0 + 8].bytes) }),
        ])
        server.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR"]
        server.bodylessUIDs = [2] // in both folders: listed, never returned
        let harness = try await EngineHarness(server: server, provider: .microsoft)
        defer { harness.cleanUp() }
        _ = try await harness.run()

        let reports = try ArchiveStatus.folders(harness.archive, account: harness.account.id)
        #expect(reports.map(\.name) == ["INBOX", "Sent Items"])
        #expect(reports.map(\.serverCount) == [6, 3])
        #expect(reports.map(\.archived) == [5, 2])
        #expect(reports.map(\.queued) == [1, 1])
        #expect(reports.allSatisfy { $0.matches })
        #expect(reports.allSatisfy { !$0.firstSyncComplete })
    }
}

extension AccountSyncer {
    /// The syncer's own session opener, to build a variant with another sink in tests.
    var openSessionForTests: @Sendable () async throws -> IMAPSession { openSession }
}
