import Foundation
import StowCore
import Testing
@testable import StowSync

/// D-121: `stowmail verify` finds stored messages that differ from the server.
@Suite struct VerifyTests {
    func verifier(_ harness: SyncHarness) -> StoreVerifier {
        let port = Int(harness.port)
        return StoreVerifier(
            account: harness.account,
            openSession: {
                let session = try await IMAPSession.connect(to: .plaintextLoopback(port: port))
                try await session.authenticate(user: "sam@example.com", accessToken: "good-token")
                return session
            },
            source: harness.store,
            budget: ByteBudget(limit: nil, fileURL: nil),
            chunkSize: 4
        )
    }

    /// The path of a stored message's .eml file.
    func emlURL(_ harness: SyncHarness, uid: UInt32) -> URL {
        FileManager.default.enumerator(at: harness.root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "\(uid).eml" && $0.deletingLastPathComponent().lastPathComponent == "7" }!
    }

    @Test func cleanStoreVerifiesAndCorruptionIsFoundByFolderAndUID() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        _ = try await harness.syncer().run()

        let clean = try await verifier(harness).run(sample: nil)
        #expect(clean.isClean && clean.compared == fixtures.count && clean.identical == fixtures.count)

        // The real failure's shape: same length, last byte moved to the front.
        let url = emlURL(harness, uid: 9)
        let original = try Data(contentsOf: url)
        try (Data([original.last!]) + original.dropLast()).write(to: url)
        // And a truncated file.
        let truncated = emlURL(harness, uid: 11)
        try Data(contentsOf: truncated).dropLast(3).write(to: truncated)

        let report = try await verifier(harness).run(sample: nil)
        #expect(report.mismatched == [VerifyItem(folderIndex: 0, uidValidity: 7, uid: 9), VerifyItem(folderIndex: 0, uidValidity: 7, uid: 11)])
        #expect(report.localSizeMismatches == [VerifyItem(folderIndex: 0, uidValidity: 7, uid: 11)])
        #expect(report.identical == fixtures.count - 2)
        #expect(!report.isClean)
        #expect(report.mismatched[0].description == "folder 1, UIDVALIDITY 7, UID 9")

        // Verify is read-only: examine and peek only, and nothing new in the store.
        assertReadOnly(harness.server.commandLog)
        #expect(try await harness.store.listKeys().count == fixtures.count)
    }

    @Test func sampleDeletedMessagesAndChangedFolders() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        _ = try await harness.syncer().run()

        let sampled = try await verifier(harness).run(sample: 5)
        #expect(sampled.sampled == 5 && sampled.compared == 5 && sampled.isClean)

        var mailboxes = harness.server.mailboxes
        let index = mailboxes.firstIndex { $0.attributes.contains("\\All") }!
        mailboxes[index].messages.removeAll { $0.uid == 3 }
        harness.server.mailboxes = mailboxes
        let afterDelete = try await verifier(harness).run(sample: nil)
        #expect(afterDelete.goneFromServer == [VerifyItem(folderIndex: 0, uidValidity: 7, uid: 3)])
        #expect(afterDelete.isClean)

        mailboxes[index].uidValidity = 8
        harness.server.mailboxes = mailboxes
        let afterReset = try await verifier(harness).run(sample: nil)
        #expect(afterReset.compared == 0)
        #expect(afterReset.skippedFolders[0] == "UIDVALIDITY changed since these were stored")
    }

    /// Verify goes through the same connection, so split replies compare clean too (D-120).
    @Test func splitRepliesVerifyClean() async throws {
        let fixtures = try Fixtures.all()
        let server = gmailServer(fixtures)
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }
        _ = try await harness.syncer().run()
        server.splitFetchReply = { literalBoundaryCuts($0) }
        let report = try await verifier(harness).run(sample: nil)
        #expect(report.isClean && report.identical == fixtures.count)
    }
}
