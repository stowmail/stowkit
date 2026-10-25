import Foundation
import GRDB
import StowCore
@testable import StowEngine
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

/// UI-12 (D-098, D-408): after the user deletes old mail at the provider, the
/// next full check shows whether anything from before the date is still there.
@Suite(.serialized) struct DeletionCheckTests {
    /// The fixtures arrived on 17 Jul 2024 (the fake server's INTERNALDATE).
    let before = Date(timeIntervalSince1970: 1_735_689_600) // 1 Jan 2025

    @Test func theCountDropsToZeroOnlyAfterAFullCheck() async throws {
        let fixtures = try TestFixtures.small()
        let server = gmailServer(fixtures)
        let harness = try await EngineHarness(server: server)
        defer { harness.cleanUp() }
        _ = try await harness.run()

        // The user is shown the instructions now; nothing has been checked since.
        let since = Date()
        let first = try Coverage.deletionCheck(harness.archive, account: harness.account.id, before: before, since: since)
        #expect(first.stillAtProvider == fixtures.count)
        #expect(first.lastFullCheck != nil && !first.isCurrent && !first.deletedAsExpected)

        // They delete everything before the date: Gmail moves it to the Bin.
        let deleted = server.mailbox(allMail).messages
        server.mutate(allMail) { $0.messages.removeAll(); $0.uidNextOverride = 100 }
        server.mutate("[Gmail]/Bin") { box in
            box.messages = deleted.enumerated().map { .init(uid: UInt32($0.offset + 1), bytes: $0.element.bytes, gmailMessageID: $0.element.gmailMessageID) }
        }
        // Still stale until a full check has run after `since` (stored in whole seconds).
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = try await harness.run(SyncOptions(checkChanges: .quick))
        #expect(try !Coverage.deletionCheck(harness.archive, account: harness.account.id, before: before, since: since).isCurrent)

        _ = try await harness.run()
        let after = try Coverage.deletionCheck(harness.archive, account: harness.account.id, before: before, since: since)
        #expect(after.isCurrent)
        #expect(after.stillAtProvider == 0 && after.stillAtProviderBytes == 0)
        #expect(after.deletedAsExpected)
        // Mail after the date is not counted either way.
        let earlier = Date(timeIntervalSince1970: 1_700_000_000) // Nov 2023
        #expect(try Coverage.deletionCheck(harness.archive, account: harness.account.id, before: earlier, since: since).stillAtProvider == 0)
    }

    @Test func messagesLeftUnclassifiedByACutShortRunAreClassifiedNextTime() async throws {
        let fixtures = try TestFixtures.small()
        let server = gmailServer(fixtures)
        let harness = try await EngineHarness(server: server)
        defer { harness.cleanUp() }
        _ = try await harness.run()

        // As if a run marked the copy removed, then lost the connection before
        // looking in the Bin: the message still says `present`.
        let gone = server.mailbox(allMail).messages[0]
        server.mutate(allMail) { box in box.messages.removeAll { $0.uid == gone.uid } }
        server.mutate("[Gmail]/Bin") { $0.messages = [.init(uid: 1, bytes: gone.bytes, gmailMessageID: gone.gmailMessageID)] }
        let goneUID = Int64(gone.uid)
        try await harness.archive.database.write { db in
            try db.execute(sql: "UPDATE message_folders SET removed_from_server_at = 1 WHERE uid = ?", arguments: [goneUID])
        }
        #expect(try harness.count("messages", "source_state = 'present'") == fixtures.count)

        let report = try await harness.run()
        #expect(report.sourceChanges == [.trashed: 1])
        #expect(try harness.count("messages", "source_state = 'trashed'") == 1)
    }
}
