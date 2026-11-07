import Foundation
import GRDB
import StowCore
import StowEngine
import StowSecrets
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

/// Plays the Gmail API for the same fixtures and Gmail IDs that
/// `seedIMAPSyncedGmail` stores as IMAP sync did, so an account synced by IMAP
/// can move to the API. It keeps
/// a history of the changes the tests make, as Gmail does.
actor FakeGmailAPI: GmailTransport {
    struct Message {
        var id: UInt64
        var bytes: Data
        var labels: [String]
    }

    enum Change {
        case added(UInt64), deleted(UInt64), labelsAdded(UInt64, [String]), labelsRemoved(UInt64, [String])
    }

    var messages: [Message]
    /// Deleted for good: gone from every listing, still named in history.
    var deleted: [UInt64: Message] = [:]
    var userLabels: [(id: String, name: String)] = []
    var history: [(id: UInt64, change: Change)] = []
    var historyID: UInt64
    /// Gmail keeps no history before this; an older start ID gets a 404.
    var historyFloor: UInt64 = 0
    let pageSize: Int
    /// IDs whose `raw` fetch answers with a reply Stow cannot read.
    var unreadable: Set<UInt64> = []
    /// `raw` fetches answered with 403 rateLimitExceeded, counting down.
    var throttledRawFetches = 0
    private(set) var paths: [String] = []

    init(_ fixtures: [(name: String, bytes: Data)], pageSize: Int = 3, historyID: UInt64 = 4242) {
        messages = fixtures.enumerated().map { index, fixture in
            Message(id: 1_900_000_000_000 + UInt64(index), bytes: fixture.bytes, labels: index == 0 ? ["INBOX"] : ["INBOX", "UNREAD"])
        }
        self.pageSize = pageSize
        self.historyID = historyID
    }

    private func record(_ change: Change) {
        historyID += 1
        history.append((historyID, change))
    }

    func remove(_ id: UInt64) { messages.removeAll { $0.id == id } }
    func setUnreadable(_ ids: Set<UInt64>) { unreadable = ids }
    func throttleRaw(_ count: Int) { throttledRawFetches = count }
    func addUserLabel(_ id: String, _ name: String) { userLabels.append((id, name)) }
    func renameUserLabel(_ id: String, to name: String) {
        userLabels = userLabels.map { $0.id == id ? (id, name) : $0 }
    }
    func expireHistory() { historyFloor = historyID + 1 }

    func deliver(_ bytes: Data, id: UInt64, labels: [String] = ["INBOX", "UNREAD"]) {
        messages.append(Message(id: id, bytes: bytes, labels: labels))
        record(.added(id))
    }

    func label(_ id: UInt64, add: [String] = [], remove: [String] = [], quietly: Bool = false) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let added = add.filter { !messages[index].labels.contains($0) }
        let removed = remove.filter { messages[index].labels.contains($0) }
        messages[index].labels = messages[index].labels.filter { !removed.contains($0) } + added
        if quietly { return }
        if !added.isEmpty { record(.labelsAdded(id, added)) }
        if !removed.isEmpty { record(.labelsRemoved(id, removed)) }
    }

    func delete(_ id: UInt64) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        deleted[id] = messages.remove(at: index)
        record(.deleted(id))
    }

    var rawFetches: Int { paths.filter { $0.contains("format=raw") }.count }

    private func ref(_ id: UInt64) -> String {
        let hex = String(id, radix: 16)
        let labels = (messages.first { $0.id == id } ?? deleted[id])?.labels ?? []
        return #"{"id":"\#(hex)","threadId":"\#(hex)","labelIds":[\#(labels.map { "\"\($0)\"" }.joined(separator: ","))]}"#
    }

    func send(_ request: GmailGet, accessToken: String) async throws -> GmailHTTPResponse {
        let url = request.url
        paths.append(url.path + "?" + (url.query ?? ""))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let rest = url.path.replacingOccurrences(of: "/gmail/v1/users/me/", with: "")
        func json(_ text: String, status: Int = 200) -> GmailHTTPResponse {
            GmailHTTPResponse(status: status, body: Data(text.utf8))
        }
        switch rest {
        case "profile":
            return json(#"{"emailAddress":"sam@example.com","messagesTotal":\#(messages.count),"historyId":"\#(historyID)"}"#)
        case "labels":
            let system = ["INBOX", "SENT", "IMPORTANT", "STARRED", "UNREAD", "SPAM", "TRASH", "DRAFT", "CATEGORY_UPDATES", "CHAT"]
                .map { #"{"id":"\#($0)","name":"\#($0)","type":"system"}"# }
            let user = userLabels.map { #"{"id":"\#($0.id)","name":"\#($0.name)","type":"user"}"# }
            return json(#"{"labels":[\#((system + user).joined(separator: ","))]}"#)
        case "history":
            let start = UInt64(query["startHistoryId"] ?? "0") ?? 0
            guard start >= historyFloor else { return json(#"{"error":{"code":404,"errors":[{"reason":"notFound"}]}}"#, status: 404) }
            var records: [String] = []
            for (id, change) in history where id > start {
                switch change {
                case .added(let m): records.append(#"{"id":"\#(id)","messagesAdded":[{"message":\#(ref(m))}]}"#)
                case .deleted(let m): records.append(#"{"id":"\#(id)","messagesDeleted":[{"message":\#(ref(m))}]}"#)
                case .labelsAdded(let m, let l):
                    records.append(#"{"id":"\#(id)","labelsAdded":[{"message":\#(ref(m)),"labelIds":[\#(l.map { "\"\($0)\"" }.joined(separator: ","))]}]}"#)
                case .labelsRemoved(let m, let l):
                    records.append(#"{"id":"\#(id)","labelsRemoved":[{"message":\#(ref(m)),"labelIds":[\#(l.map { "\"\($0)\"" }.joined(separator: ","))]}]}"#)
                }
            }
            return json(#"{"history":[\#(records.joined(separator: ","))],"historyId":"\#(historyID)"}"#)
        case "messages":
            let wanted = items.filter { $0.name == "labelIds" }.compactMap(\.value)
            let withSpamTrash = query["includeSpamTrash"] == "true"
            let matching = messages.filter { message in
                (withSpamTrash || !(message.labels.contains("SPAM") || message.labels.contains("TRASH")))
                    && wanted.allSatisfy(message.labels.contains)
            }
            let start = Int(query["pageToken"] ?? "0") ?? 0
            let page = matching.dropFirst(start).prefix(pageSize)
            let refs = page.map { #"{"id":"\#(String($0.id, radix: 16))","threadId":"\#(String($0.id, radix: 16))"}"# }.joined(separator: ",")
            let next = start + pageSize < matching.count ? #","nextPageToken":"\#(start + pageSize)""# : ""
            return json(#"{"messages":[\#(refs)]\#(next),"resultSizeEstimate":\#(matching.count)}"#)
        default:
            let hex = String(rest.dropFirst("messages/".count))
            guard let id = UInt64(hex, radix: 16), let message = messages.first(where: { $0.id == id }) else {
                return json(#"{"error":{"code":404,"errors":[{"reason":"notFound"}]}}"#, status: 404)
            }
            let labels = message.labels.map { "\"\($0)\"" }.joined(separator: ",")
            let common = #""id":"\#(hex)","threadId":"\#(hex)","labelIds":[\#(labels)],"internalDate":"1700000000000","sizeEstimate":\#(message.bytes.count)"#
            if query["format"] == "raw" {
                if throttledRawFetches > 0 {
                    throttledRawFetches -= 1
                    return json(#"{"error":{"code":403,"errors":[{"reason":"rateLimitExceeded"}]}}"#, status: 403)
                }
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
        let harness = try await EngineHarness.gmail()
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
        let harness = try await EngineHarness.gmail()
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

    /// Step 6: several requests in flight give the same archive as one, and a
    /// crash still resumes with no duplicates or gaps.
    @Test func requestsInFlightGiveTheSameArchive() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let api = FakeGmailAPI(fixtures)
        let store = ArchiveSyncStore(archive: harness.archive)
        struct Killed: Error {}
        let crashing = CrashingSink(store: store, failAfter: 3)
        await #expect(throws: Killed.self) {
            do {
                _ = try await syncer(harness, api, sink: crashing)
                    .run(SyncOptions(batches: BatchPlanner(maxMessages: 4), requestsInFlight: 4))
            } catch is CrashingSink.Crash { throw Killed() }
        }
        #expect(try harness.count("messages") == 3)
        let report = try await syncer(harness, api).run(SyncOptions(batches: BatchPlanner(maxMessages: 4), requestsInFlight: 4))
        #expect(report.messagesWritten == fixtures.count - 3)
        #expect(Set(try harness.storedBytes()) == Set(fixtures.map(\.bytes)))
        #expect(try harness.count("messages") == fixtures.count)
        #expect(try harness.count("gmail_queue") == 0)
    }

    /// `stowmail size` before the first download counts Gmail's own queue (step 6).
    @Test func theMailboxSizeCountsGmailsQueue() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        _ = try await syncer(harness, FakeGmailAPI(fixtures)).run(SyncOptions(listOnly: true))
        let size = try MailboxSize.totals(harness.archive, account: harness.account.id)
        #expect(size.messages == fixtures.count)
        #expect(size.bytes == Int64(fixtures.reduce(0) { $0 + $1.bytes.count }))
        #expect(size.quota == nil && !size.sizesAreEstimates)
    }

    /// D-598: a throttled batch stops at the refusal, keeps what it downloaded,
    /// backs off and carries on; nothing is counted against the message.
    @Test func aThrottledBatchStopsAtTheRefusal() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let api = FakeGmailAPI(fixtures)
        _ = try await syncer(harness, api).run(SyncOptions(listOnly: true))
        await api.throttleRaw(1)
        let report = try await syncer(harness, api).run(SyncOptions(batches: BatchPlanner(maxMessages: 100), requestsInFlight: 1))
        #expect(report.messagesWritten == fixtures.count)
        // One refused request, then each message once: no burst of refusals.
        #expect(await api.rawFetches == fixtures.count + 1)
        #expect(try harness.count("gmail_queue") == 0)
        #expect(try harness.count("gmail_queue", "attempts > 0") == 0)
    }

    /// Removed Gmail API mail comes back by its Gmail ID (D-598): no folder or UID needed.
    @Test func removedMailIsRestoredByGmailID() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let api = FakeGmailAPI(fixtures)
        _ = try await syncer(harness, api).run()
        let ids = try await harness.archive.database.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id LIMIT 2")
        }
        let removal = ArchiveRemoval(archive: harness.archive)
        _ = try removal.remove(ids, reason: "sender:test")
        #expect(try harness.count("messages") == fixtures.count - 2)
        let tombstones = try removal.tombstones(account: harness.account.id)
        #expect(tombstones.count == 2 && tombstones.allSatisfy(\.restorable))
        let result = try removal.requestRestore(tombstones.map(\.id))
        #expect(result.queued == 2 && result.unavailable == 0)
        let report = try await syncer(harness, api).run()
        #expect(report.messagesWritten == 2)
        #expect(try harness.count("messages") == fixtures.count)
        #expect(try harness.count("tombstones") == 0)
        #expect(Set(try harness.storedBytes()) == Set(fixtures.map(\.bytes)))
    }

    @Test func inOrderStopsStartingWorkAfterAStop() async throws {
        actor Started { var count = 0; func add() { count += 1 } }
        for width in [1, 3] {
            let started = Started()
            let out = await GmailSyncer.inOrder(Array(0..<20), width: width, stops: { $0 == 4 }) { item in
                await started.add()
                return item
            }
            #expect(out == [0, 1, 2, 3, 4])
            #expect(await started.count <= 5 + width - 1)
        }
    }

    @Test func thePacerKeepsToTheRate() async throws {
        actor Clock {
            var now = Date(timeIntervalSince1970: 0)
            var slept: TimeInterval = 0
            func advance(_ seconds: TimeInterval) { now += seconds; slept += seconds }
        }
        let clock = Clock()
        let pacer = GmailQuotaPacer(unitsPerMinute: 6_000, burst: 600, now: { Date(timeIntervalSince1970: 0) },
                                    sleep: { await clock.advance($0) })
        // The burst is free; after it every 100 units waits a second (6,000 a minute).
        try await pacer.spend(600)
        #expect(await clock.slept == 0)
        try await pacer.spend(100)
        #expect(abs(await clock.slept - 1) < 0.001)
        try await pacer.spend(200)
        #expect(abs(await clock.slept - 4) < 0.001)
        #expect(GmailReadOnlyRequest.message(GmailMessageID(number: 1), format: .raw).quotaUnits == 60)
        #expect(GmailReadOnlyRequest.message(GmailMessageID(number: 1), format: .metadata(headers: [])).quotaUnits == 20)
        #expect(GmailReadOnlyRequest.messages(GmailMessageListQuery(includeSpamTrash: false)).quotaUnits == 5)
        #expect(GmailReadOnlyRequest.history(GmailHistoryQuery(startHistoryID: 1)).quotaUnits == 2)
        #expect(GmailReadOnlyRequest.profile.quotaUnits == 1 && GmailReadOnlyRequest.labels.quotaUnits == 1)
    }

    @Test func inOrderKeepsOrderAndWidth() async throws {
        actor Gauge {
            var now = 0, most = 0
            func enter() { now += 1; most = max(most, now) }
            func leave() { now -= 1 }
        }
        for width in [1, 2, 4] {
            let gauge = Gauge()
            let out = await GmailSyncer.inOrder(Array(0..<20), width: width) { item in
                await gauge.enter()
                try? await Task.sleep(nanoseconds: UInt64((20 - item) * 200_000))
                await gauge.leave()
                return item * 10
            }
            #expect(out == (0..<20).map { $0 * 10 })
            #expect(await gauge.most <= width)
            if width > 1 { #expect(await gauge.most > 1) }
        }
    }

    /// Step 9's shape (D-591 item 4): an account synced by IMAP moves to the API
    /// with nothing downloaded again, no duplicates and nothing counted as removed.
    @Test func anIMAPSyncedAccountIsAdoptedWithoutDownloading() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        try await harness.seedIMAPSyncedGmail(fixtures)
        let before = try harness.count("messages")
        #expect(before == fixtures.count)
        #expect(try harness.count("message_folders", "uid IS NOT NULL") == fixtures.count)
        let firstIDs = try await harness.archive.database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }
        #expect(try GmailArchiveRows.count(harness.archive, account: harness.account.id).allMailRowsWithUID == fixtures.count)

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
        // What `verify --server` checks after the move: one row per Gmail ID, every All Mail copy held by ID.
        #expect(try GmailArchiveRows.count(harness.archive, account: harness.account.id)
            == GmailArchiveRows(duplicateGmailIDs: 0, allMailRowsWithUID: 0, allMailAPIRows: fixtures.count, tombstones: 0))
    }

    /// D-113 and D-115 for the API: deleted before download leaves the queue; a
    /// message whose reply is never usable is recorded after three runs.
    @Test func goneAndUnreadableMessagesAreHandledByID() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
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
        let harness = try await EngineHarness.gmail()
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

    /// Gmail accounts go to the API when `EngineSync` has tokens. Without them
    /// they get the IMAP syncer, which refuses them before connecting (D-601).
    @Test func engineSyncPicksTheAPIForGmailWithTokens() async throws {
        let server = microsoftServer(try TestFixtures.small())
        let harness = try await EngineHarness(server: server, provider: .gmail)
        defer { harness.cleanUp() }
        let syncer = try harness.sync.syncer(for: harness.account)
        #expect(syncer is AccountSyncer)
        await #expect(throws: SyncError.gmailUsesTheAPI) { _ = try await syncer.run(SyncOptions()) }
        await #expect(throws: SyncError.gmailUsesTheAPI) { _ = try await harness.sync.mailboxSize(for: harness.account) }
        #expect(server.connectionCount == 0 && server.commandLog.isEmpty)
        #expect(try harness.count("folders") == 0)
    }

    /// Gmail has no IMAP server to open a session to (D-601).
    @Test func noIMAPSessionIsMadeForGmail() async throws {
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let keychain = KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
        defer { try? keychain.deleteAll() }
        let tokens = TokenProvider(tokenStore: TokenStore(keychain: keychain), registry: ArchiveAccounts(archive: harness.archive),
                                   clientFor: { _ in throw SyncError.gmailUsesTheAPI })
        #expect(throws: SyncError.gmailUsesTheAPI) { _ = try SessionFactory(account: harness.account, in: harness.archive, tokens: tokens) }
        #expect(ProviderProfile.gmail.endpoint == nil)
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

/// Brief steps 4 and 5 (D-595 to D-597): labels, threads, and changes at Gmail.
@Suite(.serialized) struct GmailAPIChangesTests {
    let base: UInt64 = 1_900_000_000_000

    func syncer(_ harness: EngineHarness, _ api: FakeGmailAPI) -> GmailSyncer {
        let store = ArchiveSyncStore(archive: harness.archive)
        let client = GmailClient(account: harness.account.id, transport: api, markNeedsSignIn: {}) { _ in "token" }
        return GmailSyncer(account: harness.account, client: client, sink: store, state: store,
                           budget: ByteBudget(limit: nil, fileURL: nil), sleep: { _ in })
    }

    /// Per Gmail ID: the label names present, the All Mail flags, the thread key and the source state.
    func places(_ harness: EngineHarness) async throws -> [UInt64: String] {
        try await harness.archive.database.read { db in
            var result: [UInt64: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT m.gmail_msgid AS id, m.thread_key, m.source_state,
                    (SELECT group_concat(name, ',') FROM (SELECT f.name FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                        WHERE mf.message_id = m.id AND f.kind = 'label' AND mf.removed_from_server_at IS NULL ORDER BY f.name)) AS labels,
                    (SELECT mf.flags FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                        WHERE mf.message_id = m.id AND f.special_use = '\\all') AS flags
                FROM messages m
                """) {
                let labels: String? = row["labels"]
                let flags: String? = row["flags"]
                let thread: String = row["thread_key"]
                let state: String = row["source_state"]
                result[UInt64(bitPattern: row["id"])] = "\(labels ?? "") | \(flags ?? "") | \(thread) | \(state)"
            }
            return result
        }
    }

    /// QA: a message looks the same whichever way it arrived: label names, read
    /// state and thread as IMAP sync stored them (D-595).
    @Test func labelsFlagsAndThreadsMatchIMAP() async throws {
        let fixtures = try TestFixtures.small()
        let imap = try await EngineHarness.gmail()
        defer { imap.cleanUp() }
        try await imap.seedIMAPSyncedGmail(fixtures)
        let api = try await EngineHarness.gmail()
        defer { api.cleanUp() }
        _ = try await syncer(api, FakeGmailAPI(fixtures)).run()
        let viaIMAP = try await places(imap)
        let viaAPI = try await places(api)
        #expect(viaAPI.count == fixtures.count)
        #expect(viaAPI == viaIMAP)
        #expect(viaAPI[base]?.hasPrefix("\\Inbox | \\Seen | g:") == true)
        // Tabs, Spam, Bin and read state are not labels in the archive.
        #expect(try api.count("folders", "kind = 'label' AND (name LIKE 'CATEGORY%' OR name IN ('UNREAD', 'SPAM', 'TRASH', 'CHAT'))") == 0)
    }

    /// A label renamed in Gmail is renamed in the archive, found by its ID; a
    /// label of the new name already there becomes the same label (D-595).
    @Test func aRenamedLabelKeepsItsMessages() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let gmail = FakeGmailAPI(fixtures)
        await gmail.addUserLabel("Label_7", "Receipts")
        await gmail.label(base + 1, add: ["Label_7"], quietly: true)
        _ = try await syncer(harness, gmail).run()
        #expect(try await places(harness)[base + 1]?.hasPrefix("Receipts,\\Inbox |") == true)

        // An IMAP-era label "Bills" with another message on it, then the rename.
        let message2 = try await harness.archive.database.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM messages WHERE gmail_msgid = ?", arguments: [Int64(self.base + 2)])!
        }
        try await harness.archive.database.write { db in
            try db.execute(sql: "INSERT INTO folders (account_id, name, kind) VALUES (?, 'Bills', 'label')", arguments: [harness.account.id.rawValue])
            try db.execute(sql: "INSERT INTO message_folders (message_id, folder_id, last_seen_at) VALUES (?, ?, 0)",
                           arguments: [message2, db.lastInsertedRowID])
        }
        await gmail.renameUserLabel("Label_7", to: "Bills")
        _ = try await syncer(harness, gmail).run()
        let after = try await places(harness)
        #expect(after[base + 1]?.hasPrefix("Bills,\\Inbox |") == true)
        #expect(after[base + 2]?.hasPrefix("Bills,\\Inbox |") == true)
        #expect(try harness.count("folders", "kind = 'label' AND name IN ('Receipts', 'Bills')") == 1)
        #expect(try harness.count("folders", "kind = 'label' AND name = 'Bills' AND provider_id = 'Label_7'") == 1)
    }

    /// QA: history picks up new mail, label changes and deletions; Spam and Bin
    /// are classified, and nothing is ever deleted from the archive (D-596).
    @Test func historyBringsNewMailLabelChangesAndRemovals() async throws {
        let fixtures = try TestFixtures.small()
        #expect(fixtures.count >= 6)
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let gmail = FakeGmailAPI(Array(fixtures.prefix(5)))
        await gmail.addUserLabel("Label_1", "Travel")
        _ = try await syncer(harness, gmail).run()
        #expect(try harness.count("messages") == 5)

        await gmail.deliver(fixtures[5].bytes, id: base + 5)       // new mail
        await gmail.label(base, add: ["STARRED", "Label_1"])        // starred and labelled
        await gmail.label(base + 1, remove: ["UNREAD"])             // read on the web
        await gmail.label(base + 2, add: ["TRASH"])                 // binned
        await gmail.label(base + 3, add: ["SPAM"])                  // marked spam
        await gmail.delete(base + 4)                                // deleted for good
        let report = try await syncer(harness, gmail).run()
        #expect(report.messagesWritten == 1 && report.queued == 1)
        #expect(report.sourceChanges == [.trashed: 1, .spam: 1, .gone: 1])

        let now = try await places(harness)
        #expect(now.count == 6)
        #expect(now[base]?.hasPrefix("Travel,\\Inbox,\\Starred | \\Flagged \\Seen |") == true)
        #expect(now[base + 1]?.hasPrefix("\\Inbox | \\Seen |") == true)
        #expect(now[base + 2]?.hasSuffix("| trashed") == true)
        #expect(now[base + 3]?.hasSuffix("| spam") == true)
        #expect(now[base + 4]?.hasSuffix("| gone") == true)
        #expect(now[base + 5]?.hasPrefix("\\Inbox |  |") == true)

        // Taken back out of the Bin: present again, nothing downloaded twice.
        await gmail.label(base + 2, remove: ["TRASH"])
        let back = try await syncer(harness, gmail).run()
        #expect(back.messagesWritten == 0)
        #expect(try await places(harness)[base + 2]?.hasSuffix("| present") == true)
        #expect(try harness.count("messages") == 6)
        let state = try #require(try await ArchiveSyncStore(archive: harness.archive).gmailState(harness.account.id))
        #expect(state.historyID == (await gmail.historyID))
    }

    /// Spam that arrives is not archived (D-104); moved out of Spam, it is.
    @Test func mailDeliveredToSpamIsQueuedOnlyWhenTakenOut() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let gmail = FakeGmailAPI(Array(fixtures.prefix(2)))
        _ = try await syncer(harness, gmail).run()
        await gmail.deliver(fixtures[2].bytes, id: base + 2, labels: ["SPAM", "UNREAD"])
        #expect(try await syncer(harness, gmail).run().queued == 0)
        await gmail.label(base + 2, remove: ["SPAM"])
        await gmail.label(base + 2, add: ["INBOX"])
        let report = try await syncer(harness, gmail).run()
        #expect(report.queued == 1 && report.messagesWritten == 1)
    }

    /// A history ID Gmail no longer keeps (404) falls back to a full listing and
    /// check, which finds what history would have said (D-597).
    @Test func anExpiredHistoryIDFallsBackToAFullCheck() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let gmail = FakeGmailAPI(Array(fixtures.prefix(5)))
        _ = try await syncer(harness, gmail).run()
        await gmail.label(base + 1, add: ["TRASH"])
        await gmail.delete(base + 2)
        await gmail.deliver(fixtures[5].bytes, id: base + 5)
        await gmail.expireHistory()
        let report = try await syncer(harness, gmail).run()
        #expect(report.sourceChanges == [.trashed: 1, .gone: 1])
        #expect(report.messagesWritten == 1)
        let state = try #require(try await ArchiveSyncStore(archive: harness.archive).gmailState(harness.account.id))
        #expect(state.historyID == (await gmail.historyID))
        #expect(state.lastFullCheckAt != nil)
        // The Spam and Bin lookups ask for IDs only.
        let lookups = await gmail.paths.filter { $0.contains("labelIds=") }
        #expect(lookups.count == 2 && lookups.allSatisfy { $0.contains("includeSpamTrash=true") && !$0.contains("format=") })
    }

    /// The six-hourly full check catches a change history never reported.
    @Test func theFullCheckFindsWhatHistoryMissed() async throws {
        let fixtures = try TestFixtures.small()
        let harness = try await EngineHarness.gmail()
        defer { harness.cleanUp() }
        let gmail = FakeGmailAPI(Array(fixtures.prefix(4)))
        _ = try await syncer(harness, gmail).run()
        await gmail.label(base + 3, add: ["SPAM"], quietly: true)
        #expect(try await syncer(harness, gmail).run(SyncOptions(checkChanges: .quick)).sourceChanges.isEmpty)
        let full = try await syncer(harness, gmail).run(SyncOptions(checkChanges: .full))
        #expect(full.sourceChanges == [.spam: 1])
        #expect(try await places(harness)[base + 3]?.hasSuffix("| spam") == true)
    }
}

extension EngineHarness {
    /// The archive an IMAP sync of `fixtures` left behind before Gmail moved to
    /// the API (D-601 removed that path): the folders it recorded, and All Mail
    /// (special use `\all`) holding every message at UIDVALIDITY 7 and a sparse
    /// UID, with its Gmail ID, thread ID, `\Inbox` label and flags, written
    /// through `ArchiveSyncStore` as IMAP sync wrote them.
    func seedIMAPSyncedGmail(_ fixtures: [(name: String, bytes: Data)]) async throws {
        let store = ArchiveSyncStore(archive: archive)
        let allMail = ArchiveSyncStore.gmailAllMailName
        try await store.recordFolders(account.id, [
            SyncFolder(name: "INBOX", delimiter: "/", skippedReason: "label: its messages come from All Mail, with labels attached"),
            SyncFolder(name: "[Gmail]", delimiter: "/", isSelectable: false, skippedReason: "cannot be opened (\\Noselect)"),
            SyncFolder(name: allMail, delimiter: "/", specialUse: "\\all"),
            SyncFolder(name: "[Gmail]/Spam", delimiter: "/", specialUse: "\\junk", skippedReason: "Spam: not in All Mail, not archived (D-104)"),
            SyncFolder(name: "[Gmail]/Bin", delimiter: "/", specialUse: "\\trash", skippedReason: "Bin: not in All Mail, not archived (D-104)"),
        ])
        _ = try await store.beginFolder(account.id, folder: allMail, uidValidity: 7, exists: fixtures.count)
        for (index, fixture) in fixtures.enumerated() {
            let gmailID = 1_900_000_000_000 + UInt64(index)
            try await store.write(RawMessage(
                key: RawMessageKey(accountID: account.id, folder: allMail, uidValidity: 7, uid: UInt32(index * 2 + 3)),
                labels: ["\\Inbox"], gmailMessageID: gmailID, gmailThreadID: gmailID,
                internalDate: Date(timeIntervalSince1970: 1_721_209_465), // the fake IMAP server's INTERNALDATE
                size: fixture.bytes.count, flags: index == 0 ? ["\\Seen"] : [], bytes: fixture.bytes))
        }
        try await store.folderChecked(account.id, folder: allMail, uidValidity: 7, highestModSeq: 1, fullCheck: true, at: Date())
    }
}
