import Foundation
import GRDB
import StowCore
import StowEngine
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

/// Plays the Gmail API for the same fixtures and Gmail IDs that `gmailServer`
/// serves over IMAP, so an account synced by IMAP can move to the API.
actor FakeGmailAPI: GmailTransport {
    struct Message {
        var id: UInt64
        var bytes: Data
        var labels: [String]
    }

    var messages: [Message]
    let pageSize: Int
    let historyID: UInt64
    /// IDs whose `raw` fetch answers with a reply Stow cannot read.
    var unreadable: Set<UInt64> = []
    private(set) var paths: [String] = []

    init(_ fixtures: [(name: String, bytes: Data)], pageSize: Int = 3, historyID: UInt64 = 4242) {
        messages = fixtures.enumerated().map { index, fixture in
            Message(id: 1_900_000_000_000 + UInt64(index), bytes: fixture.bytes, labels: index == 0 ? ["INBOX"] : ["INBOX", "UNREAD"])
        }
        self.pageSize = pageSize
        self.historyID = historyID
    }

    func remove(_ id: UInt64) { messages.removeAll { $0.id == id } }
    func setUnreadable(_ ids: Set<UInt64>) { unreadable = ids }

    var rawFetches: Int { paths.filter { $0.contains("format=raw") }.count }

    func send(_ request: GmailGet, accessToken: String) async throws -> GmailHTTPResponse {
        let url = request.url
        paths.append(url.path + "?" + (url.query ?? ""))
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        let rest = url.path.replacingOccurrences(of: "/gmail/v1/users/me/", with: "")
        func json(_ text: String, status: Int = 200) -> GmailHTTPResponse {
            GmailHTTPResponse(status: status, body: Data(text.utf8))
        }
        switch rest {
        case "profile":
            return json(#"{"emailAddress":"sam@example.com","messagesTotal":\#(messages.count),"historyId":"\#(historyID)"}"#)
        case "messages":
            let start = Int(query["pageToken"] ?? "0") ?? 0
            let page = messages.dropFirst(start).prefix(pageSize)
            let refs = page.map { #"{"id":"\#(String($0.id, radix: 16))","threadId":"\#(String($0.id, radix: 16))"}"# }.joined(separator: ",")
            let next = start + pageSize < messages.count ? #","nextPageToken":"\#(start + pageSize)""# : ""
            return json(#"{"messages":[\#(refs)]\#(next),"resultSizeEstimate":\#(messages.count)}"#)
        default:
            let hex = String(rest.dropFirst("messages/".count))
            guard let id = UInt64(hex, radix: 16), let message = messages.first(where: { $0.id == id }) else {
                return json(#"{"error":{"code":404,"errors":[{"reason":"notFound"}]}}"#, status: 404)
            }
            let labels = message.labels.map { "\"\($0)\"" }.joined(separator: ",")
            let common = #""id":"\#(hex)","threadId":"\#(hex)","labelIds":[\#(labels)],"internalDate":"1700000000000","sizeEstimate":\#(message.bytes.count)"#
            if query["format"] == "raw" {
                if unreadable.contains(id) { return json(#"{"id":"\#(hex)"}"#) }
                let raw = message.bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return json(#"{\#(common),"raw":"\#(raw)"}"#)
            }
            return json(#"{\#(common),"payload":{"headers":[{"name":"From","value":"someone@example.com"}]}}"#)
        }
    }
}

/// Brief step 3 (D-591): listing and downloading through the Gmail API into a real archive.
@Suite(.serialized) struct GmailAPISyncTests {
    func syncer(_ harness: EngineHarness, _ api: FakeGmailAPI, sink: RawMessageSink? = nil) -> GmailSyncer {
        let store = ArchiveSyncStore(archive: harness.archive)
        let client = GmailClient(account: harness.account.id, transport: api, markNeedsSignIn: {}) { _ in "token" }
        return GmailSyncer(account: harness.account, client: client, sink: sink ?? store, state: store,
                           budget: ByteBudget(limit: nil, fileURL: nil), sleep: { _ in })
    }

    func readerLevel(_ harness: EngineHarness) throws -> String? {
        try harness.archive.database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = 'min_reader_level'")
        }
    }

    @Test func aNewAccountSyncsEverythingByteForByteWithNoUIDs() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        let api = FakeGmailAPI(fixtures)

        let report = try await syncer(harness, api).run(SyncOptions(batches: BatchPlanner(maxMessages: 4)))
        #expect(report.messagesWritten == fixtures.count && report.queued == fixtures.count)
        #expect(report.remaining == QueueTotals())
        #expect(Set(try harness.storedBytes()) == Set(fixtures.map(\.bytes)))
        // Every copy is on All Mail with no UID; Gmail IDs and threads as IMAP stored them.
        #expect(try harness.count("message_folders mf JOIN folders f ON f.id = mf.folder_id", "f.special_use = '\\all' AND mf.uid IS NULL") == fixtures.count)
        #expect(try harness.count("messages", "gmail_msgid >= 1900000000000 AND thread_key LIKE 'g:%'") == fixtures.count)
        // Read state as IMAP sync stored it: only the first fixture had no UNREAD label.
        #expect(try harness.count("message_folders", "flags = '\\Seen'") == 1)
        // The cursor and the reader level (D-591 items 2 and 5).
        let state = try #require(try await ArchiveSyncStore(archive: harness.archive).gmailState(harness.account.id))
        #expect(state.historyID == 4242 && state.fullListingCompletedAt != nil && state.firstSyncCompletedAt != nil)
        #expect(try readerLevel(harness) == "3")
        // Nothing but reads: profile, list pages, metadata and raw gets.
        let paths = await api.paths
        #expect(paths.allSatisfy { $0.hasPrefix("/gmail/v1/users/me/") })
        #expect(paths.filter { $0.contains("format=metadata") }.count == fixtures.count)
        #expect(await api.rawFetches == fixtures.count)

        // `stowmail status` and the coverage date read the API's state (D-591).
        let status = try #require(try ArchiveStatus.collect(harness.archive).first { $0.account.account.id == harness.account.id })
        #expect(status.firstSyncComplete && status.foldersSynced == 1 && status.queue == QueueTotals())
        #expect(status.coverageDate != nil)
        let folders = try ArchiveStatus.folders(harness.archive, account: harness.account.id)
        #expect(folders.count == 1 && folders[0].archived == fixtures.count && folders[0].firstSyncComplete)

        // A second run downloads nothing and lists nothing again.
        let again = try await syncer(harness, api).run()
        #expect(again.messagesWritten == 0 && again.queued == 0)
        #expect(await api.rawFetches == fixtures.count)
    }

    /// QA: killing the process mid-sync and starting again gives no duplicates and no gaps.
    @Test func aCrashMidDownloadResumesWithNoDuplicatesOrGaps() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        let api = FakeGmailAPI(fixtures)
        let store = ArchiveSyncStore(archive: harness.archive)
        struct Killed: Error {}
        let crashing = CrashingSink(store: store, failAfter: 3)
        await #expect(throws: Killed.self) {
            do { _ = try await syncer(harness, api, sink: crashing).run(SyncOptions(batches: BatchPlanner(maxMessages: 2))) }
            catch is CrashingSink.Crash { throw Killed() }
        }
        #expect(try harness.count("messages") == 3)
        let report = try await syncer(harness, api).run()
        #expect(report.messagesWritten == fixtures.count - 3)
        #expect(try harness.count("messages") == fixtures.count)
        #expect(Set(try harness.storedBytes()) == Set(fixtures.map(\.bytes)))
        #expect(try harness.count("gmail_queue") == 0)
    }

    /// Step 9's shape (D-591 item 4): an account synced by IMAP moves to the API
    /// with nothing downloaded again, no duplicates and nothing counted as removed.
    @Test func anIMAPSyncedAccountIsAdoptedWithoutDownloading() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        _ = try await harness.run()
        let before = try harness.count("messages")
        #expect(before == fixtures.count)
        #expect(try harness.count("message_folders", "uid IS NOT NULL") == fixtures.count)
        let firstIDs = try await harness.archive.database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }

        let api = FakeGmailAPI(fixtures)
        let report = try await syncer(harness, api).run()
        #expect(report.messagesWritten == 0 && report.queued == 0)
        #expect(await api.rawFetches == 0)
        #expect(await api.paths.filter { $0.contains("format=metadata") }.isEmpty)
        let afterIDs = try await harness.archive.database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }
        #expect(afterIDs == firstIDs)
        #expect(try harness.count("message_folders mf JOIN folders f ON f.id = mf.folder_id", "f.special_use = '\\all' AND mf.uid IS NULL") == fixtures.count)
        #expect(try harness.count("message_folders", "removed_from_server_at IS NOT NULL") == 0)
        #expect(try harness.count("tombstones") == 0)
        #expect(try harness.count("messages", "source_state != 'present'") == 0)
        #expect(try readerLevel(harness) == "3")
    }

    /// D-113 and D-115 for the API: deleted before download leaves the queue; a
    /// message whose reply is never usable is recorded after three runs.
    @Test func goneAndUnreadableMessagesAreHandledByID() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        let api = FakeGmailAPI(fixtures)
        let store = ArchiveSyncStore(archive: harness.archive)
        // List only, then change Gmail before anything downloads.
        _ = try await syncer(harness, api).run(SyncOptions(listOnly: true))
        #expect(try harness.count("gmail_queue") == fixtures.count)
        await api.remove(1_900_000_000_001)
        await api.setUnreadable([1_900_000_000_002])

        for run in 1...3 {
            let report = try await syncer(harness, api).run()
            #expect(report.recordedUnfetchable == (run == 3 ? 1 : 0))
            #expect(report.notDownloaded == (run == 3 ? 0 : 1))
        }
        #expect(try harness.count("messages") == fixtures.count - 2)
        #expect(try harness.count("gmail_queue", "state = 'unfetchable'") == 1)
        #expect(try harness.count("gmail_queue", "state = 'queued'") == 0)
        // An unfetchable message holds the coverage date back, as over IMAP.
        let held = try #require(try ArchiveStatus.collect(harness.archive).first { $0.account.account.id == harness.account.id })
        #expect(held.queue.unfetchable == 1 && held.coverageDate != nil)
        #expect(try await store.queueTotals(harness.account.id) == QueueTotals(queued: 0, queuedBytes: 0, unfetchable: 1))
        // A fourth run does not try it again.
        let before = await api.rawFetches
        _ = try await syncer(harness, api).run()
        #expect(await api.rawFetches == before)
    }

    /// A message the user removed from the archive is never downloaded again (D-033).
    @Test func aTombstonedGmailIDIsNotQueued() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        try await harness.archive.database.write { db in
            try db.execute(sql: """
                INSERT INTO tombstones (account_id, raw_hash, gmail_msgid, internal_date, size, reason, removed_at)
                VALUES (?, ?, ?, 0, 1, 'sender:x', 0)
                """, arguments: [harness.account.id.rawValue, Data(repeating: 7, count: 32), Int64(1_900_000_000_000)])
        }
        let report = try await syncer(harness, FakeGmailAPI(fixtures)).run()
        #expect(report.messagesWritten == fixtures.count - 1)
        #expect(try harness.count("messages", "gmail_msgid = 1900000000000") == 0)
    }

    /// Gmail accounts go to the API when `EngineSync` has tokens; IMAP otherwise.
    @Test func engineSyncPicksTheAPIForGmailWithTokens() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness(server: gmailServer(fixtures))
        defer { harness.cleanUp() }
        #expect(try harness.sync.syncer(for: harness.account) is AccountSyncer)
    }
}

/// A sink that stores the first `failAfter` messages, then fails as a killed process would.
final class CrashingSink: RawMessageSink, @unchecked Sendable {
    struct Crash: Error {}
    let store: ArchiveSyncStore
    let failAfter: Int
    private var written = 0
    private let lock = NSLock()

    init(store: ArchiveSyncStore, failAfter: Int) {
        self.store = store
        self.failAfter = failAfter
    }

    func write(_ message: RawMessage) async throws {
        let count = lock.withLock { written += 1; return written }
        if count > failAfter { throw Crash() }
        try await store.write(message)
    }

    func flush() async throws {}
}
