import Foundation
import StowCore
import StowSecrets
import Testing
@testable import StowSync

/// Runs `AccountSyncer` against the fake server and a real `FileRawMessageStore`.
struct SyncHarness {
    let server: FakeIMAPServer
    let port: UInt16
    let root: URL
    let store: FileRawMessageStore
    let account: Account
    let sleeps = RecordedSleeps()

    init(server: FakeIMAPServer, provider: Provider = .gmail) async throws {
        self.server = server
        port = try await server.start()
        root = temporaryDirectory(".noindex")
        store = try FileRawMessageStore(root: root)
        account = Account(id: AccountID(rawValue: "acct-\(UUID().uuidString.prefix(8).lowercased())"), provider: provider, email: "sam@example.com", displayName: "Sam")
    }

    func syncer(
        sink: RawMessageSink? = nil,
        budget: ByteBudget = ByteBudget(limit: nil, fileURL: nil),
        unfetchable: UnfetchableLedger = UnfetchableLedger(fileURL: nil),
        token: String = "good-token"
    ) -> AccountSyncer {
        let port = Int(self.port)
        let sleeps = self.sleeps
        return AccountSyncer(
            account: account,
            openSession: {
                let session = try await IMAPSession.connect(to: .plaintextLoopback(port: port), timeouts: IMAPTimeouts(connect: 5, read: 5))
                try await session.authenticate(user: "sam@example.com", accessToken: token)
                return session
            },
            sink: sink ?? store,
            checkpoints: store,
            budget: budget,
            unfetchable: unfetchable,
            sleep: { try await sleeps.sleep($0) }
        )
    }

    func cleanUp() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func storedUIDs() async throws -> [UInt32] {
        try await store.listKeys().map(\.uid)
    }
}

/// Wraps a sink and fails on the given flush, to simulate the process dying
/// after a batch was written but before its checkpoint was saved.
actor CrashingSink: RawMessageSink {
    let inner: RawMessageSink
    let crashOnFlush: Int
    private var flushes = 0

    init(_ inner: RawMessageSink, crashOnFlush: Int) {
        self.inner = inner
        self.crashOnFlush = crashOnFlush
    }

    func write(_ message: RawMessage) async throws { try await inner.write(message) }

    func flush() async throws {
        flushes += 1
        if flushes == crashOnFlush { throw CocoaError(.fileWriteUnknown) }
        try await inner.flush()
    }
}

@Suite struct AccountSyncerTests {
    @Test func gmailSyncDownloadsAllMailOnlyByteForByteWithLabels() async throws {
        let fixtures = try Fixtures.all() // includes the 15 MiB message
        let harness = try await SyncHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 10)))
        #expect(report.outcome == .complete)
        #expect(report.messagesWritten == fixtures.count)
        #expect(report.foldersSynced == 1)

        let keys = try await harness.store.listKeys()
        #expect(keys.count == fixtures.count)
        #expect(Set(keys.map(\.folder)) == ["[Gmail]/Tous les messages"])
        #expect(Set(keys.map(\.uidValidity)) == [7])
        for (index, key) in keys.sorted(by: { $0.uid < $1.uid }).enumerated() {
            let stored = try await harness.store.read(key)
            #expect(stored.bytes == fixtures[index].bytes, "fixture \(fixtures[index].name) changed in transit")
            #expect(stored.size == fixtures[index].bytes.count)
            #expect(stored.gmailMessageID == 1_800_000_000_000 + UInt64(index))
            #expect(stored.labels == (index % 2 == 0 ? ["\\Inbox", "Receipts"] : ["\\Important"]))
        }
        let checkpoint = try await harness.store.checkpoint(accountID: harness.account.id, folder: "[Gmail]/Tous les messages")
        #expect(checkpoint?.highestUID == keys.map(\.uid).max())
        #expect(checkpoint?.uidValidity == 7)

        let log = harness.server.commandLog
        assertReadOnly(log)
        // Only All Mail was opened: never a label, Spam or Bin.
        #expect(log.filter { $0.contains("EXAMINE") }.allSatisfy { $0.contains("Tous les messages") })
        #expect(log.contains { $0.contains("X-GM-LABELS") })

        // A second run finds nothing new and downloads nothing.
        let fetchesBefore = harness.server.bodyFetchCount
        let again = try await harness.syncer().run()
        #expect(again.messagesWritten == 0)
        #expect(harness.server.bodyFetchCount == fetchesBefore)
    }

    @Test func picksUpNewMessagesAfterTheCheckpoint() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        _ = try await harness.syncer().run()

        var mailboxes = harness.server.mailboxes
        let index = mailboxes.firstIndex { $0.attributes.contains("\\All") }!
        // No labels at all, as Gmail sends for an archived message: X-GM-LABELS ().
        mailboxes[index].messages.append(.init(uid: 500, bytes: Data("Subject: new\r\n\r\nnew\r\n".utf8), labels: [], gmailMessageID: 42, gmailThreadID: 42))
        harness.server.mailboxes = mailboxes

        let report = try await harness.syncer().run()
        #expect(report.messagesWritten == 1)
        #expect(try await harness.storedUIDs().last == 500)
        let key = try #require(try await harness.store.listKeys().last)
        #expect(try await harness.store.read(key).labels == [])
    }

    /// QA: a dropped connection mid-sync reconnects and resumes with no gaps and no duplicates.
    @Test func resumesAfterADroppedConnection() async throws {
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures)
        server.dropOnBodyFetchNumber = 3
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 4)))
        #expect(report.outcome == .complete)
        #expect(report.messagesWritten == fixtures.count)
        #expect(harness.sleeps.delays == [2])
        #expect(harness.server.connectionCount == 2)
        let uids = try await harness.storedUIDs()
        #expect(uids == (0..<fixtures.count).map { UInt32($0 * 2 + 3) })
        // The dropped batch was never answered, so no body was sent twice.
        #expect(harness.server.bodiesServed.values.allSatisfy { $0 == 1 })
    }

    /// QA: killing the process mid-sync and restarting gives no duplicates and no gaps.
    @Test func restartAfterACrashBetweenWriteAndCheckpoint() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }

        let crashing = CrashingSink(harness.store, crashOnFlush: 3)
        await #expect(throws: CocoaError.self) {
            _ = try await harness.syncer(sink: crashing).run(SyncOptions(batches: BatchPlanner(maxMessages: 4)))
        }
        // Batches 1 and 2 are checkpointed; batch 3 was written but not checkpointed.
        let checkpoint = try await harness.store.checkpoint(accountID: harness.account.id, folder: "[Gmail]/Tous les messages")
        #expect(checkpoint?.highestUID == 17) // the 8th message: UID 8*2+1

        // A fresh run (a new process) repeats batch 3 and finishes.
        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 4)))
        #expect(report.outcome == .complete)
        let uids = try await harness.storedUIDs()
        #expect(uids == (0..<fixtures.count).map { UInt32($0 * 2 + 3) }) // no gaps, no duplicates
        // Only batch 3 was downloaded twice.
        #expect(harness.server.bodiesServed.values.filter { $0 == 2 }.count == 4)
    }

    @Test func cancellingStopsCleanlyAndALaterRunFinishes() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }

        let syncer = harness.syncer()
        let task = Task {
            try await syncer.run(SyncOptions(batches: BatchPlanner(maxMessages: 2))) { event in
                if case .batchWritten = event {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await #expect(throws: SyncError.cancelled) { _ = try await task.value }
        let partial = try await harness.storedUIDs()
        #expect(!partial.isEmpty && partial.count < fixtures.count)

        let report = try await harness.syncer().run()
        #expect(report.outcome == .complete)
        #expect(try await harness.storedUIDs() == (0..<fixtures.count).map { UInt32($0 * 2 + 3) })
    }

    @Test func uidValidityChangeResyncsTheFolder() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures, uidValidity: 7))
        defer { harness.cleanUp() }
        _ = try await harness.syncer().run()

        var mailboxes = harness.server.mailboxes
        let index = mailboxes.firstIndex { $0.attributes.contains("\\All") }!
        mailboxes[index].uidValidity = 8
        harness.server.mailboxes = mailboxes

        let report = try await harness.syncer().run()
        #expect(report.uidValidityResets == 1)
        #expect(report.messagesWritten == fixtures.count)
        let keys = try await harness.store.listKeys()
        #expect(keys.filter { $0.uidValidity == 8 }.count == fixtures.count)
        #expect(keys.filter { $0.uidValidity == 7 }.count == fixtures.count) // the old copies are kept
        let checkpoint = try await harness.store.checkpoint(accountID: harness.account.id, folder: "[Gmail]/Tous les messages")
        #expect(checkpoint?.uidValidity == 8)
    }

    @Test func limitStopsAndTheNextRunContinues() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }

        let first = try await harness.syncer().run(SyncOptions(limit: 3))
        #expect(first.outcome == .limitReached)
        #expect(first.messagesWritten == 3)
        #expect(try await harness.storedUIDs() == [3, 5, 7])

        let second = try await harness.syncer().run()
        #expect(second.outcome == .complete)
        #expect(second.messagesWritten == fixtures.count - 3)
    }

    @Test func byteBudgetStopsTheSyncAndPersists() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        let budgetFile = harness.root.deletingLastPathComponent().appendingPathComponent("budget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: budgetFile) }

        let firstTwo = Int64(fixtures.prefix(2).reduce(0) { $0 + $1.bytes.count })
        let budget = ByteBudget(limit: firstTwo + 10, fileURL: budgetFile)
        let report = try await harness.syncer(budget: budget).run(SyncOptions(batches: BatchPlanner(maxMessages: 2)))
        #expect(report.outcome == .budgetExhausted(usedBytes: firstTwo, limitBytes: firstTwo + 10))
        #expect(report.messagesWritten == 2)

        // A new process sees the same spend and downloads nothing more today.
        let reloaded = ByteBudget(limit: firstTwo + 10, fileURL: budgetFile)
        #expect(await reloaded.used() == firstTwo)
        let again = try await harness.syncer(budget: reloaded).run(SyncOptions(batches: BatchPlanner(maxMessages: 2)))
        #expect(again.messagesWritten == 0)
    }

    @Test func throttlingByeBacksOffAndRetries() async throws {
        let server = gmailServer(try Fixtures.small())
        server.byeOnBodyFetchNumber = (1, "[UNAVAILABLE] Server busy, try again later")
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }
        let report = try await harness.syncer().run()
        #expect(report.outcome == .complete)
        #expect(harness.sleeps.delays == [2])
    }

    @Test func dailyQuotaByeStopsWithoutRetrying() async throws {
        let server = gmailServer(try Fixtures.small())
        server.byeOnBodyFetchNumber = (1, "[OVERQUOTA] Account exceeded command or bandwidth limits")
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }
        await #expect {
            _ = try await harness.syncer().run()
        } throws: { error in
            if case SyncError.quotaExceeded = error { return true }
            return false
        }
        #expect(harness.sleeps.delays.isEmpty)
    }

    @Test func repeatedFailuresWithoutProgressGiveUp() async throws {
        let server = gmailServer(try Fixtures.small())
        server.dropEveryBodyFetch = true
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }
        await #expect(throws: SyncError.self) { _ = try await harness.syncer().run() }
        #expect(harness.sleeps.delays == [2, 4, 8, 16, 32])
        #expect(harness.server.connectionCount == 6)
    }

    @Test func rejectedTokenIsNotRetried() async throws {
        let harness = try await SyncHarness(server: gmailServer(try Fixtures.small()))
        defer { harness.cleanUp() }
        await #expect {
            _ = try await harness.syncer(token: "revoked").run()
        } throws: { error in
            if case SyncError.authenticationFailed = error { return true }
            return false
        }
        #expect(harness.sleeps.delays.isEmpty)
        #expect(harness.server.connectionCount == 1)
    }

    @Test func microsoftSyncsEverySelectableFolderExceptJunk() async throws {
        let fixtures = try Fixtures.small()
        func messages(_ range: Range<Int>) -> [FakeIMAPServer.Message] {
            range.map { FakeIMAPServer.Message(uid: UInt32($0 + 1), bytes: fixtures[$0].bytes) }
        }
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "INBOX", attributes: ["\\HasNoChildren"], uidValidity: 11, messages: messages(0..<4)),
            .init(name: "Sent Items", attributes: ["\\Sent", "\\HasNoChildren"], uidValidity: 12, messages: messages(4..<6)),
            .init(name: "Deleted Items", attributes: ["\\Trash", "\\HasNoChildren"], uidValidity: 13, messages: messages(6..<7)),
            .init(name: "Junk Email", attributes: ["\\Junk", "\\HasNoChildren"], uidValidity: 14, messages: messages(7..<9)),
            .init(name: "Archive", attributes: ["\\HasChildren", "\\Noselect"], uidValidity: 15, messages: []),
            .init(name: "Archive/2019", attributes: ["\\HasNoChildren"], uidValidity: 16, messages: messages(9..<10)),
        ])
        server.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR"]
        let harness = try await SyncHarness(server: server, provider: .microsoft)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run()
        #expect(report.foldersSynced == 4)
        #expect(report.messagesWritten == 8)
        let keys = try await harness.store.listKeys()
        #expect(Set(keys.map(\.folder)) == ["INBOX", "Sent Items", "Deleted Items", "Archive/2019"])
        for key in keys {
            let stored = try await harness.store.read(key)
            #expect(stored.labels.isEmpty)
            #expect(stored.gmailMessageID == nil)
        }
        let log = harness.server.commandLog
        assertReadOnly(log)
        #expect(!log.contains { $0.contains("X-GM-") })
        #expect(!log.contains { $0.contains("Junk") })
    }
}

@Suite struct SessionFactoryTests {
    @Test func refusedTokenIsRefreshedOnceThenWorks() async throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let server = gmailServer([])
        server.acceptedTokens = ["fresh-token"]
        let port = try await server.start()
        defer { server.stop() }

        let registry = AccountRegistry(keychain: keychain)
        let tokens = TokenStore(keychain: keychain)
        let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Sam")
        try registry.add(AccountRecord(account: account))
        try tokens.save(OAuthTokens(accessToken: "stale-token", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)), for: account.id)
        let endpoint = FakeTokenEndpoint { _ in (200, #"{"access_token":"fresh-token","expires_in":3600}"#) }
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .google(testAppConfig), http: endpoint) }

        let factory = SessionFactory(account: account, endpoint: .plaintextLoopback(port: Int(port)), tokens: provider)
        let session = try await factory.open()
        await session.logout()
        #expect(await endpoint.requests.count == 1)
        #expect(server.connectionCount == 2)

        // If even the fresh token is refused, that is final: one refresh, no loop.
        server.acceptedTokens = []
        await #expect {
            _ = try await factory.open()
        } throws: { error in
            if case SyncError.authenticationFailed = error { return true }
            return false
        }
        #expect(await endpoint.requests.count == 2)
    }
}

/// Fixes from part 2 (orchestrator, 2026-10-23).
@Suite struct MissingMessageTests {
    static let allMail = "[Gmail]/Tous les messages"

    /// The Microsoft 365 bug: the server lists UIDs but returns no FETCH data.
    /// The checkpoint must not pass them, and nothing after them may be skipped.
    @Test func listedButNotReturnedNeverAdvancesPastThem() async throws {
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures) // UIDs 3, 5, 7, 9, ...
        server.bodylessUIDs = [9]
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let first = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(first.notDownloaded == [0: 1])
        #expect(try await harness.store.checkpoint(accountID: harness.account.id, folder: Self.allMail)?.highestUID == 7)
        // A rerun stops at the same place: still incomplete, never silently skipped.
        let second = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(second.notDownloaded == [0: 1])
        #expect(try await harness.store.checkpoint(accountID: harness.account.id, folder: Self.allMail)?.highestUID == 7)

        // Once the server returns it, the next run fills the gap and finishes.
        server.bodylessUIDs = []
        let third = try await harness.syncer().run()
        #expect(third.notDownloaded.isEmpty)
        #expect(try await harness.storedUIDs() == (0..<fixtures.count).map { UInt32($0 * 2 + 3) })
    }

    @Test func messagesDeletedBetweenListingAndFetchAreConfirmedGoneThenPassed() async throws {
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures)
        server.expungeOnBodyFetch = [9, 11]
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(report.notDownloaded.isEmpty)
        #expect(report.outcome == .complete)
        let expected = (0..<fixtures.count).map { UInt32($0 * 2 + 3) }.filter { $0 != 9 && $0 != 11 }
        #expect(try await harness.storedUIDs() == expected)
        #expect(try await harness.store.checkpoint(accountID: harness.account.id, folder: Self.allMail)?.highestUID == expected.last)
        // The re-list was a UID FETCH of just the missing UIDs, without bodies.
        #expect(harness.server.commandLog.contains { $0.contains("UID FETCH 9,11 (UID RFC822.SIZE FLAGS INTERNALDATE)") })
    }

    /// A whole folder of non-mail items (a calendar the name rules miss) stops
    /// that folder, reports it, and the other folders still sync.
    @Test func unfetchableFolderIsReportedAndOthersContinue() async throws {
        let fixtures = try Fixtures.small()
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "Gym", attributes: ["\\HasNoChildren"], uidValidity: 21, messages: (1...5).map { .init(uid: UInt32($0), bytes: fixtures[0].bytes) }),
            .init(name: "INBOX", attributes: ["\\HasNoChildren"], uidValidity: 22, messages: (1...3).map { .init(uid: UInt32($0 + 10), bytes: fixtures[$0].bytes) }),
        ])
        server.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR"]
        server.bodylessUIDs = [1, 2, 3, 4, 5]
        let harness = try await SyncHarness(server: server, provider: .microsoft)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run()
        #expect(report.notDownloaded == [0: 5])
        #expect(report.messagesWritten == 3)
        #expect(try await harness.store.checkpoint(accountID: harness.account.id, folder: "Gym")?.highestUID == 0)
        #expect(try await harness.storedUIDs() == [11, 12, 13])
        #expect(SyncError.messagesNotDownloaded(folders: 1, messages: 5).description.contains("nothing after them was skipped"))
    }

    /// Cosmetic fix: the announced count covers the whole folder even when the
    /// first listing window is empty (Gmail UIDs are sparse).
    @Test func announcedCountIsRightWhenTheFirstWindowIsEmpty() async throws {
        let fixtures = try Fixtures.small()
        let harness = try await SyncHarness(server: gmailServer(fixtures)) // first UID is 3
        defer { harness.cleanUp() }
        let counts = AnnouncedCounts()
        _ = try await harness.syncer().run(SyncOptions(listWindow: 2)) { event in
            if case .folderStarted(_, _, let count) = event { counts.add(count) }
        }
        #expect(counts.values == [fixtures.count])
    }
}

final class AnnouncedCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    func add(_ value: Int) { lock.withLock { _values.append(value) } }
    var values: [Int] { lock.withLock { _values } }
}

/// D-115: messages listed but never returned are recorded after three separate runs.
@Suite struct UnfetchableTests {
    static let allMail = "[Gmail]/Tous les messages"

    @Test func ledgerCountsOncePerRunAndRecordsAtTheThreshold() async throws {
        let file = temporaryDirectory().appendingPathComponent("acct.unfetchable.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ledger = UnfetchableLedger(fileURL: file, threshold: 3)
        let stuck = [MessageSummary(uid: 9, size: 1234, internalDate: Date(timeIntervalSince1970: 1_700_000_000), flags: ["\\Seen"])]

        #expect(try await ledger.recordAttempt(folder: "F", uidValidity: 1, runID: "a", stuck: stuck).isEmpty)
        #expect(try await ledger.recordAttempt(folder: "F", uidValidity: 1, runID: "a", stuck: stuck).isEmpty) // same run
        #expect(try await ledger.recordAttempt(folder: "F", uidValidity: 1, runID: "b", stuck: stuck).isEmpty)
        #expect(try await ledger.recordAttempt(folder: "F", uidValidity: 1, runID: "c", stuck: stuck) == [9])

        let reloaded = UnfetchableLedger(fileURL: file, threshold: 3)
        let entry = try #require(await reloaded.entries(folder: "F").first)
        #expect(entry.attempts == 3 && entry.size == 1234 && entry.flags == ["\\Seen"] && entry.recordedAt != nil)
        #expect(entry.internalDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(await reloaded.totals() == (1, 0))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        // A UIDVALIDITY change starts the count again.
        #expect(try await reloaded.recordAttempt(folder: "F", uidValidity: 2, runID: "d", stuck: stuck).isEmpty)
        // A message that later downloads is forgotten.
        try await reloaded.resolve(folder: "F", uidValidity: 2, uids: [9])
        #expect(await reloaded.entries(folder: "F").isEmpty)
    }

    /// The Deleted Items case: the folder stops on runs 1 and 2, then on run 3
    /// the stuck messages are recorded and everything after them syncs.
    @Test func stuckMessagesAreRecordedOnTheThirdRunAndSyncContinues() async throws {
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures) // UIDs 3, 5, 7, 9, 11, ...
        server.bodylessUIDs = [9, 11]
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }
        let ledgerFile = harness.root.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).unfetchable.json")
        defer { try? FileManager.default.removeItem(at: ledgerFile) }
        func run() async throws -> SyncReport {
            try await harness.syncer(unfetchable: UnfetchableLedger(fileURL: ledgerFile)).run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        }

        for _ in 1...2 {
            let report = try await run()
            #expect(report.notDownloaded == [0: 2])
            #expect(report.recordedUnfetchable.isEmpty)
            #expect(try await harness.store.checkpoint(accountID: harness.account.id, folder: Self.allMail)?.highestUID == 7)
        }
        let third = try await run()
        #expect(third.notDownloaded.isEmpty)
        #expect(third.recordedUnfetchable == [0: 2])
        #expect(third.outcome == .complete)
        let expected = (0..<fixtures.count).map { UInt32($0 * 2 + 3) }.filter { $0 != 9 && $0 != 11 }
        #expect(try await harness.storedUIDs() == expected)
        #expect(try await harness.store.checkpoint(accountID: harness.account.id, folder: Self.allMail)?.highestUID == expected.last)

        let entries = await UnfetchableLedger(fileURL: ledgerFile).entries(folder: Self.allMail)
        #expect(entries.map(\.uid) == [9, 11])
        #expect(entries.allSatisfy { $0.attempts == 3 && $0.size > 0 && $0.internalDate != nil })

        // A fourth run has nothing left to do and reports nothing new.
        let fourth = try await run()
        #expect(fourth.messagesWritten == 0 && fourth.recordedUnfetchable.isEmpty && fourth.notDownloaded.isEmpty)
    }

    /// Reconnects inside one run do not count as extra attempts.
    @Test func retriesWithinARunCountOnce() async throws {
        let fixtures = try Fixtures.small()
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "Deleted Items", attributes: ["\\Trash"], uidValidity: 31, messages: (1...3).map { .init(uid: UInt32($0), bytes: fixtures[$0].bytes) }),
            .init(name: "INBOX", attributes: [], uidValidity: 32, messages: (1...4).map { .init(uid: UInt32($0), bytes: fixtures[$0].bytes) }),
        ])
        server.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR"]
        server.bodylessUIDs = [2] // Deleted Items UID 2 is never returned (fetch 1), so that folder stops
        server.dropOnBodyFetchNumber = 2 // then the first INBOX fetch drops; the run reconnects and redoes Deleted Items
        let harness = try await SyncHarness(server: server, provider: .microsoft)
        defer { harness.cleanUp() }
        let ledger = UnfetchableLedger(fileURL: nil)
        _ = try? await harness.syncer(unfetchable: ledger).run()
        #expect(harness.server.connectionCount == 2) // one reconnect within the run
        #expect(await ledger.entries(folder: "Deleted Items").first?.attempts == 1)
    }
}

@Suite struct MailboxUnavailableTests {
    /// A personal Microsoft account with no Outlook.com mailbox: Exchange accepts
    /// the token, then says "User is authenticated but not connected."
    @Test func noMailboxIsItsOwnErrorAndDoesNotMarkTheAccount() async throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let server = gmailServer([])
        server.authFailureText = "User is authenticated but not connected."
        let port = try await server.start()
        defer { server.stop() }

        let registry = AccountRegistry(keychain: keychain)
        let tokens = TokenStore(keychain: keychain)
        let account = Account(id: .generate(), provider: .microsoft, email: "sam@example.com", displayName: "Sam")
        try registry.add(AccountRecord(account: account))
        try tokens.save(OAuthTokens(accessToken: "good-token", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)), for: account.id)
        let endpoint = FakeTokenEndpoint { _ in (200, #"{"access_token":"other","expires_in":3600}"#) }
        let provider = TokenProvider(tokenStore: tokens, registry: registry) { _ in OAuthClient(config: .microsoft(testAppConfig), http: endpoint) }

        let factory = SessionFactory(account: account, endpoint: .plaintextLoopback(port: Int(port)), tokens: provider)
        await #expect {
            _ = try await factory.open()
        } throws: { error in
            guard case SyncError.mailboxUnavailable(let text) = error else { return false }
            let message = (error as! SyncError).description
            return text.contains("authenticated but not connected") && message.contains("no Outlook.com or Exchange Online mailbox")
                && !message.contains("stowmail account signin") && !(error as! SyncError).isRetryable
        }
        #expect(await endpoint.requests.isEmpty) // a new token cannot help, so none is asked for
        #expect(try registry.record(account.id)?.needsSignIn == false)
        #expect(server.connectionCount == 1)
    }

    @Test func otherRefusalsStayAuthenticationFailures() {
        #expect(IMAPSession.classifyAuthenticationFailure("NO AUTHENTICATE failed.") == .authenticationFailed("NO AUTHENTICATE failed."))
        #expect(IMAPSession.classifyAuthenticationFailure("NO User is authenticated but not connected.") == .mailboxUnavailable("NO User is authenticated but not connected."))
    }
}

/// D-118: Microsoft 365 sometimes returns only part of a FETCH batch, then the
/// rest on a later try. Missing UIDs are retried within the run first.
@Suite struct PartialFetchTests {
    static let allMail = "[Gmail]/Tous les messages"

    @Test func uidsLeftOutOnceAreRecoveredWithinTheRun() async throws {
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures) // UIDs 3, 5, 7, ...
        server.refusals = [9: 1, 13: 1]
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }
        let ledger = UnfetchableLedger(fileURL: nil)

        let report = try await harness.syncer(unfetchable: ledger).run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(report.notDownloaded.isEmpty)
        #expect(report.outcome == .complete)
        #expect(try await harness.storedUIDs() == (0..<fixtures.count).map { UInt32($0 * 2 + 3) })
        #expect(harness.sleeps.delays == [2]) // one short pause, no reconnect
        #expect(await ledger.totals() == (0, 0))
        // The retry asked for just the missing UIDs.
        #expect(harness.server.commandLog.contains { $0.contains("UID FETCH 9,13 (") })
    }

    @Test func stubbornUIDsAreFetchedOneAtATimeAfterTheSecondPause() async throws {
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures)
        server.refusals = [9: 2, 13: 2]
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(report.notDownloaded.isEmpty)
        #expect(harness.sleeps.delays == [2, 5])
        let log = harness.server.commandLog
        #expect(log.contains { $0.contains("UID FETCH 9 (") } && log.contains { $0.contains("UID FETCH 13 (") })
        #expect(try await harness.storedUIDs().count == fixtures.count)
    }

    @Test func stillMissingAfterTheRetriesFallsThroughToD113() async throws {
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures)
        server.refusals = [9: 3]
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let first = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(first.notDownloaded == [0: 1])
        #expect(try await harness.store.checkpoint(accountID: harness.account.id, folder: Self.allMail)?.highestUID == 7)
        // Transient: the next run gets it, and the folder completes.
        let second = try await harness.syncer().run()
        #expect(second.notDownloaded.isEmpty)
        #expect(try await harness.storedUIDs().count == fixtures.count)
    }

    /// A NO completion on a partial FETCH is a partial reply, not a fatal error,
    /// and its status, code and untagged text are logged at notice.
    @Test func noCompletionIsPartialAndDiagnosticsAreLogged() async throws {
        _ = CapturedLogs.installed
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures)
        server.refusals = [9: 1]
        server.partialCompletion = "NO [UNAVAILABLE] Some messages could not be FETCHed (Failure)"
        server.partialUntagged = "NO Item 9 is temporarily unavailable"
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(report.notDownloaded.isEmpty)
        #expect(try await harness.storedUIDs().count == fixtures.count)

        let lines = CapturedLogs.shared.all.filter { $0.contains("Partial FETCH reply") && $0.contains("\(harness.account.id)") }
        let line = try #require(lines.first)
        #expect(line.hasPrefix("notice"))
        #expect(line.contains("status: NO") || line.contains("\"status\": NO") || line.contains("status\": \"NO"))
        #expect(line.contains("UNAVAILABLE") || line.contains("unavailable"))
        #expect(line.contains("temporarily unavailable"))
        #expect(line.contains("asked: 6") || line.contains("\"asked\": 6") || line.contains("asked\": \"6"))
        #expect(!line.contains("sam@example.com"))
    }
}
