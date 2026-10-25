import Foundation
import StowCore
@testable import StowEngine
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

/// R6 (D-055 step 5, D-404): the mailbox's size before anything downloads.
@Suite(.serialized) struct MailboxSizeTests {
    @Test func gmailSizeAndQuotaWithoutDownloading() async throws {
        let fixtures = try TestFixtures.small()
        let server = gmailServer(fixtures)
        server.capabilities.append("QUOTA")
        server.storageQuotaKiB = (used: 6_500_000, limit: 15_728_640) // about 6.2 of 15 GiB
        let harness = try await EngineHarness(server: server)
        defer { harness.cleanUp() }

        let size = try await harness.sync.mailboxSize(for: harness.account)
        #expect(size.messages == fixtures.count)
        #expect(size.bytes == Int64(fixtures.map(\.bytes.count).reduce(0, +)))
        #expect(!size.sizesAreEstimates)
        #expect(size.quotaAdvertised)
        #expect(size.quota == MailboxQuota(usedBytes: 6_500_000 * 1024, limitBytes: 15_728_640 * 1024))
        // Nothing was downloaded or compared, and only read-only commands were sent.
        #expect(try harness.count("messages") == 0)
        #expect(server.bodyFetchCount == 0)
        #expect(server.commandLog.contains { $0.contains("GETQUOTAROOT") })
        #expect(readOnlyViolations(server.commandLog).isEmpty)

        // After the import, the same figures as `stowmail stats`.
        _ = try await harness.run()
        let stats = try ArchiveStats.collect(harness.archive)
        let again = try MailboxSize.totals(harness.archive, account: harness.account.id)
        #expect(again.messages == stats.messages && Int(again.bytes) == stats.rawBytes)
        #expect(again.messages == size.messages && again.bytes == size.bytes)
    }

    @Test func noQuotaCommandWhenTheServerDoesNotOfferIt() async throws {
        let fixtures = try TestFixtures.small()
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "INBOX", attributes: [], uidValidity: 11,
                  messages: fixtures.enumerated().map { .init(uid: UInt32($0.offset + 1), bytes: $0.element.bytes) }),
        ])
        server.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR"]
        let harness = try await EngineHarness(server: server, provider: .microsoft)
        defer { harness.cleanUp() }

        let size = try await harness.sync.mailboxSize(for: harness.account)
        #expect(size.messages == fixtures.count)
        #expect(size.sizesAreEstimates)
        #expect(!size.quotaAdvertised && size.quota == nil)
        #expect(!server.commandLog.contains { $0.uppercased().contains("QUOTA") })
    }

    @Test func aRefusedQuotaGivesSizeOnly() async throws {
        let fixtures = try TestFixtures.small()
        let server = gmailServer(fixtures)
        server.capabilities.append("QUOTA") // offered, but answers NO
        let harness = try await EngineHarness(server: server)
        defer { harness.cleanUp() }
        let size = try await harness.sync.mailboxSize(for: harness.account)
        #expect(size.quotaAdvertised && size.quota == nil)
        #expect(size.messages == fixtures.count)
    }
}
