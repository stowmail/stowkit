import Foundation
import Logging
import StowCore

/// What the scheduler, the CLI and the mailbox size need from a syncer, so a
/// Gmail account can sync through the Gmail API and every other account over
/// IMAP behind the same call (D-583).
public protocol MailSyncer: Sendable {
    var account: Account { get }
    func run(_ options: SyncOptions, onEvent: @escaping @Sendable (SyncEvent) -> Void) async throws -> SyncReport
}

extension MailSyncer {
    public func run(_ options: SyncOptions = SyncOptions()) async throws -> SyncReport {
        try await run(options, onEvent: { _ in })
    }
}

extension AccountSyncer: MailSyncer {}

/// Downloads a Gmail account through the Gmail API into a `RawMessageSink`,
/// keeping its progress in a `GmailSyncStateStore` (D-583, D-591, brief step 3).
///
/// A run has two parts:
/// 1. **List**, until the first full listing has finished: take Gmail's history
///    ID, then page through `messages.list` without Spam and Bin (D-104). Each
///    page is sorted by the archive: messages archived before are adopted (no
///    download), known ones skipped, and new ones get a `metadata` fetch for their
///    size, date and the header fields the rules read (D-028) before they are
///    queued. An interrupted listing starts again next run and skips what it has.
/// 2. **Download**: take the best-priority messages from the queue, fetch each
///    in `raw` format, write it to the sink and flush; the archive takes it off
///    the queue in the transaction that stores it. A message Gmail no longer has
///    leaves the queue; one that keeps failing is recorded as unfetchable after
///    `unfetchableThreshold` runs (D-113, D-115).
///
/// Once the first listing has finished, each run reads `history.list` from the
/// stored history ID instead: new messages are queued, label and read-state
/// changes applied, and messages moved to Spam or Bin or deleted are classified
/// (D-039). A history ID Gmail no longer knows (404) falls back to a full
/// listing and check. With `checkChanges: .full` (every six hours, D-038) the
/// run also lists every ID again and classifies what is missing.
///
/// Labels are read at the start of each run and stored by their stable ID, with
/// the names Gmail sync always stored (D-595).
public struct GmailSyncer: MailSyncer {
    public let account: Account
    let client: GmailClient
    let sink: RawMessageSink
    let state: GmailSyncStateStore & SyncStateStore
    let budget: ByteBudget
    let prioritiser: DownloadPrioritiser?
    let unfetchableThreshold: Int
    let retry: RetryPolicy
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let now: @Sendable () -> Date
    private let logger = Logger(label: "ee.getstow.sync.gmail")

    public init(
        account: Account,
        tokens: TokenProvider,
        sink: RawMessageSink,
        state: GmailSyncStateStore & SyncStateStore,
        budget: ByteBudget,
        prioritiser: DownloadPrioritiser? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.init(account: account, client: GmailClient(account: account.id, tokens: tokens), sink: sink, state: state,
                  budget: budget, prioritiser: prioritiser, sleep: sleep)
    }

    init(
        account: Account,
        client: GmailClient,
        sink: RawMessageSink,
        state: GmailSyncStateStore & SyncStateStore,
        budget: ByteBudget,
        prioritiser: DownloadPrioritiser? = nil,
        unfetchableThreshold: Int = AccountSyncer.defaultUnfetchableThreshold,
        retry: RetryPolicy = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.client = client
        self.sink = sink
        self.state = state
        self.budget = budget
        self.prioritiser = prioritiser
        self.unfetchableThreshold = max(1, unfetchableThreshold)
        self.retry = retry
        self.sleep = sleep
        self.now = now
    }

    /// Runs until everything is downloaded, the limit, budget or deadline is
    /// reached, or a non-retryable error occurs. Retryable failures (429, 5xx,
    /// a dropped connection) pause with back-off and carry on (D-107).
    public func run(_ options: SyncOptions, onEvent: @escaping @Sendable (SyncEvent) -> Void) async throws -> SyncReport {
        var report = SyncReport()
        let runID = UUID().uuidString
        var failuresWithoutProgress = 0
        var attempt = 0
        while true {
            attempt += 1
            let before = report.messagesWritten
            do {
                try await runOnce(options, runID: runID, report: &report, attempt: attempt, onEvent: onEvent)
                report.remaining = try await state.queueTotals(account.id)
                return report
            } catch let error as SyncError where error.isRetryable {
                failuresWithoutProgress = report.messagesWritten > before ? 1 : failuresWithoutProgress + 1
                guard failuresWithoutProgress <= retry.maxAttempts else { throw error }
                if let deadline = options.deadline, now() >= deadline { throw error }
                let delay = retry.delay(forAttempt: failuresWithoutProgress)
                logger.notice("Gmail sync interrupted; will try again", metadata: [
                    "account": "\(account.id)", "reason": "\(error)", "delay": "\(delay)",
                ])
                onEvent(.retrying(after: delay, attempt: failuresWithoutProgress, reason: error.description))
                do {
                    try await sleep(delay)
                } catch {
                    throw SyncError.cancelled
                }
            }
        }
    }

    private func runOnce(_ options: SyncOptions, runID: String, report: inout SyncReport, attempt: Int,
                         onEvent: @Sendable (SyncEvent) -> Void) async throws {
        // Asks for a token first, so an old or missing permission stops here (D-589).
        let profile = try await client.profile()
        onEvent(.connected(attempt: attempt))
        let allMail = try await state.gmailAllMail(account.id)
        onEvent(.folderPlanned(toSync: 1, skipped: 0))
        let labels = try await readLabels()

        // 1. List, until a full listing has finished once; then read what changed.
        let saved = try await state.gmailState(account.id)
        var listingDone = saved?.fullListingCompletedAt != nil
        if !listingDone {
            try await state.beginGmailSync(account.id)
            listingDone = try await list(historyID: profile.historyID, options: options, report: &report)
            onEvent(.folderListed(index: 0, of: 1, newMessages: report.queued))
        } else if !options.listOnly {
            var needsFullCheck = options.checkChanges == .full
            if let start = saved?.historyID {
                do {
                    try await readHistory(from: start, labels: labels, report: &report)
                } catch is GmailNotFound {
                    // Gmail no longer has history that far back (D-597): list everything again.
                    logger.notice("History ID too old; checking the whole mailbox", metadata: ["account": "\(account.id)"])
                    needsFullCheck = true
                }
            } else {
                needsFullCheck = true
            }
            if needsFullCheck {
                try await fullCheck(historyID: profile.historyID, options: options, report: &report, onEvent: onEvent)
            }
            onEvent(.folderListed(index: 0, of: 1, newMessages: report.queued))
        }
        report.foldersSynced = 1
        if options.listOnly { return }

        // 2. Download from the queue, best priority first.
        let totals = try await state.queueTotals(account.id)
        if totals.queued > 0 { onEvent(.downloading(queued: totals.queued, bytes: totals.queuedBytes)) }
        report.outcome = try await download(allMail: allMail, labels: labels, options: options, runID: runID, report: &report, onEvent: onEvent)
        if listingDone { try await state.gmailQueueChecked(account.id, at: now()) }
    }

    // MARK: - 1. Listing

    /// Pages through All Mail without Spam and Bin. Returns whether the listing
    /// reached its last page; a deadline stops it between pages.
    private func list(historyID: UInt64, options: SyncOptions, report: inout SyncReport, seen: ((Set<UInt64>) -> Void)? = nil) async throws -> Bool {
        var pageToken: String?
        repeat {
            let page = try await client.messages(GmailMessageListQuery(includeSpamTrash: false, pageToken: pageToken))
            seen?(Set(page.messages.map(\.id.number)))
            let sort = try await state.sortGmailListing(account.id, ids: page.messages.map(\.id.number), at: now())
            if sort.adopted > 0 {
                logger.info("Adopted messages archived before", metadata: ["account": "\(account.id)", "count": "\(sort.adopted)"])
            }
            let threads = Dictionary(page.messages.map { ($0.id.number, $0.threadID.number) }, uniquingKeysWith: { first, _ in first })
            var queued: [GmailQueuedMessage] = []
            var stopped: Error?
            let described = await Self.inOrder(sort.new, width: options.requestsInFlight, stops: Self.endsBatch) { id in
                await Self.capture { try await describe(id, thread: threads[id]) }
            }
            describing: for result in described {
                switch result {
                case .success(let message): if let message { queued.append(message) }
                case .failure(let error): stopped = error; break describing
                }
            }
            // What was described before a failure is kept, so the retry does not ask again.
            report.queued += try await state.enqueueGmail(account.id, queued)
            if let stopped { throw stopped }
            pageToken = page.nextPageToken
            if pageToken != nil, let deadline = options.deadline, now() >= deadline { return false }
        } while pageToken != nil
        try await state.gmailListingCompleted(account.id, historyID: historyID, at: now())
        return true
    }

    /// Size, date and priority for a newly listed message, from a `metadata`
    /// fetch. Nil when Gmail deleted it since the listing. A reply Stow cannot
    /// read queues it with no size, so the download and D-115 deal with it.
    private func describe(_ id: UInt64, thread: UInt64?) async throws -> GmailQueuedMessage? {
        let message: GmailMessage
        do {
            message = try await client.message(GmailMessageID(number: id), format: .metadata(headers: PriorityHeaderFields.names))
        } catch is GmailNotFound {
            return nil
        } catch SyncError.protocolViolation {
            return GmailQueuedMessage(gmailID: id, threadID: thread, size: 0)
        }
        var priority = 0
        if let prioritiser {
            let block = message.headers.map { "\($0.name): \($0.value)\r\n" }.joined()
            priority = prioritiser(Data(block.utf8))
        }
        return GmailQueuedMessage(gmailID: id, threadID: message.threadID.number, size: Int(message.sizeEstimate ?? 0),
                                  internalDate: message.internalDate, priority: priority)
    }

    // MARK: - 2. Downloading

    private func download(allMail: String, labels: [String: String], options: SyncOptions, runID: String, report: inout SyncReport,
                          onEvent: @Sendable (SyncEvent) -> Void) async throws -> SyncOutcome {
        var batches = 0
        while true {
            if let limit = options.limit, report.messagesWritten >= limit { return .limitReached }
            // At least one batch per turn, so a slow listing can never starve the downloads.
            if batches > 0, let deadline = options.deadline, now() >= deadline { return .yielded }
            batches += 1
            let room = options.limit.map { $0 - report.messagesWritten } ?? options.batches.maxMessages
            let batch = try await state.nextGmailDownloads(account.id, runID: runID, maxMessages: min(room, options.batches.maxMessages),
                                                           maxBytes: options.batches.maxBytes)
            guard !batch.isEmpty else { return .complete }
            let planned = Int64(batch.reduce(0) { $0 + $1.size })
            guard try await budget.allows(planned) else {
                return .budgetExhausted(usedBytes: try await budget.used(), limitBytes: budget.limit ?? 0, neededBytes: planned)
            }

            var bytes: Int64 = 0
            var written = 0
            var gone: [UInt64] = []
            var failed: [UInt64] = []
            var stopped: Error?
            // Fetched up to `requestsInFlight` at a time, written one by one in queue order.
            let fetched = await Self.inOrder(batch, width: options.requestsInFlight, stops: Self.endsBatch) { queued in
                await Self.capture { try await client.message(GmailMessageID(number: queued.gmailID), format: .raw) }
            }
            writing: for (queued, result) in zip(batch, fetched) {
                let message: GmailMessage
                switch result {
                case .success(let fetchedMessage):
                    message = fetchedMessage
                case .failure(let error) where error is GmailNotFound:
                    gone.append(queued.gmailID)
                    continue
                case .failure(SyncError.protocolViolation), .failure(SyncError.commandFailed):
                    // This message's reply was unusable; others carry on (D-113).
                    failed.append(queued.gmailID)
                    continue
                case .failure(let error):
                    // Anything else (429, 5xx, offline, sign-in) ends the batch here;
                    // what came before it is still written and flushed below.
                    stopped = error
                    break writing
                }
                guard let raw = message.raw else { failed.append(queued.gmailID); continue }
                try await sink.write(RawMessage(
                    key: .gmailAPI(accountID: account.id, allMail: allMail),
                    labels: Self.labelNames(message.labelIDs, labels),
                    gmailMessageID: queued.gmailID,
                    gmailThreadID: message.threadID.number,
                    internalDate: message.internalDate ?? queued.internalDate ?? now(),
                    size: raw.count,
                    flags: Self.flags(message.labelIDs),
                    bytes: raw
                ))
                bytes += Int64(raw.count)
                written += 1
            }
            // Each write commits with its queue row gone; flush keeps the sink's contract.
            try await sink.flush()
            if !gone.isEmpty {
                try await state.gmailVanishedBeforeDownload(account.id, ids: gone)
                logger.notice("Listed messages were deleted at Gmail before download", metadata: [
                    "account": "\(account.id)", "count": "\(gone.count)",
                ])
            }
            if !failed.isEmpty {
                let recorded = try await state.recordGmailFailedAttempt(account.id, runID: runID, ids: failed, threshold: unfetchableThreshold)
                report.recordedUnfetchable += recorded.count
                report.notDownloaded += failed.count - recorded.count
                if !recorded.isEmpty { onEvent(.unfetchableRecorded(count: recorded.count)) }
                if failed.count > recorded.count { onEvent(.notDownloaded(count: failed.count - recorded.count)) }
            }
            try await budget.record(bytes)
            report.messagesWritten += written
            report.bytesWritten += bytes
            onEvent(.batchWritten(messages: written, bytes: bytes))
            if let stopped { throw stopped }
        }
    }

    /// The outcome of one request, success or error, so several can run at once
    /// and be handled in order afterwards.
    static func capture<Output: Sendable>(_ body: () async throws -> Output) async -> Result<Output, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Runs `work` on each item with at most `width` running at once, and
    /// returns the results in the items' order. Once an output `stops` (Google
    /// asked Stow to slow down, the network went), nothing new is started: the
    /// results end at the first stopping one, in order, so a throttled batch
    /// sends no more requests (D-598).
    static func inOrder<Item: Sendable, Output: Sendable>(
        _ items: [Item], width: Int, stops: @escaping (Output) -> Bool = { _ in false },
        _ work: @escaping @Sendable (Item) async -> Output
    ) async -> [Output] {
        guard width > 1, items.count > 1 else {
            var outputs: [Output] = []
            for item in items {
                let output = await work(item)
                outputs.append(output)
                if stops(output) { break }
            }
            return outputs
        }
        return await withTaskGroup(of: (Int, Output).self) { group in
            var outputs = [Output?](repeating: nil, count: items.count)
            var next = 0
            var stopped = false
            while next < min(width, items.count) {
                let index = next, item = items[index]
                group.addTask { (index, await work(item)) }
                next += 1
            }
            while let (index, output) = await group.next() {
                outputs[index] = output
                if stops(output) { stopped = true }
                if !stopped, next < items.count {
                    let index = next, item = items[index]
                    group.addTask { (index, await work(item)) }
                    next += 1
                }
            }
            // The finished prefix, up to and including the first stopping output.
            var ordered: [Output] = []
            for output in outputs {
                guard let output else { break }
                ordered.append(output)
                if stops(output) { break }
            }
            return ordered
        }
    }

    /// Whether a request's outcome should stop the batch: anything but success
    /// or a per-message problem (gone, unreadable) the batch carries on past.
    static func endsBatch<Output>(_ result: Result<Output, Error>) -> Bool {
        guard case .failure(let error) = result else { return false }
        if error is GmailNotFound { return false }
        switch error as? SyncError {
        case .protocolViolation?, .commandFailed?: return false
        default: return true
        }
    }

    /// Gmail's read and starred state as the IMAP flags Gmail sync always
    /// stored, so a message looks the same whichever way it arrived:
    /// no `UNREAD` label is `\Seen`, `STARRED` is `\Flagged`.
    static func flags(_ labels: [GmailLabelID]) -> [String] {
        let names = Set(labels.map(\.rawValue))
        var flags: [String] = []
        if names.contains("STARRED") { flags.append("\\Flagged") }
        if !names.contains("UNREAD") { flags.append("\\Seen") }
        return flags
    }

    // MARK: - Labels (D-595)

    /// Gmail's system labels by the names Gmail sync stores from `X-GM-LABELS`
    /// (and Takeout import uses, D-566). Other system labels (`UNREAD`, `SPAM`,
    /// `TRASH`, `CATEGORY_*`, `CHAT`) are not labels in the archive: read state is
    /// a flag, Spam and Bin a source state, tabs are dropped.
    static let systemLabelNames = ["INBOX": "\\Inbox", "SENT": "\\Sent", "IMPORTANT": "\\Important",
                                   "STARRED": "\\Starred", "DRAFT": "\\Draft"]

    /// Reads `labels.list` and stores the labels by ID; returns ID to stored name.
    private func readLabels() async throws -> [String: String] {
        let names = try await labelNamesByID()
        try await state.recordGmailLabels(account.id, names.map { GmailLabelName(id: $0.key, name: $0.value) }.sorted { $0.id < $1.id })
        return names
    }

    /// The account's labels as Stow names them, read from Gmail and not
    /// recorded, for `stowmail folders`. Sorted by name.
    public func labelNames() async throws -> [String] {
        try await labelNamesByID().values.sorted()
    }

    private func labelNamesByID() async throws -> [String: String] {
        var names: [String: String] = [:]
        for label in try await client.labels() {
            if label.type == .user {
                names[label.id.rawValue] = label.name
            } else if let name = Self.systemLabelNames[label.id.rawValue] {
                names[label.id.rawValue] = name
            }
        }
        // System labels are always there, whether or not labels.list named them.
        for (id, name) in Self.systemLabelNames where names[id] == nil { names[id] = name }
        return names
    }

    static func labelNames(_ ids: [GmailLabelID], _ names: [String: String]) -> [String] {
        ids.compactMap { names[$0.rawValue] }
    }

    // MARK: - Changes at Gmail (brief step 5)

    /// Reads every page of `history.list` from `start` and applies it. New
    /// messages (and ones taken back out of Spam or Bin that the archive does not
    /// have) are queued; label and read-state changes go to archived copies;
    /// messages moved to Spam or Bin, or deleted, are classified (D-039).
    private func readHistory(from start: UInt64, labels: [String: String], report: inout SyncReport) async throws {
        var pageToken: String?
        var newest = start
        repeat {
            let page = try await client.history(GmailHistoryQuery(startHistoryID: start, pageToken: pageToken))
            newest = max(newest, page.historyID)
            var added: [UInt64: UInt64] = [:]
            var changes: [GmailCopyChange] = []
            var states: [SourceState: [UInt64]] = [:]
            for record in page.history {
                for change in record.messagesAdded {
                    let ids = Set(change.message.labelIDs)
                    if ids.contains(.spam) || ids.contains(.trash) { continue }
                    added[change.message.id.number] = change.message.threadID.number
                }
                for change in record.messagesDeleted {
                    states[.gone, default: []].append(change.message.id.number)
                }
                for change in record.labelsAdded {
                    let id = change.message.id.number
                    if change.labelIDs.contains(.spam) {
                        states[.spam, default: []].append(id)
                    } else if change.labelIDs.contains(.trash) {
                        states[.trashed, default: []].append(id)
                    }
                    changes.append(Self.copyChange(id, added: change.labelIDs, removed: [], labels: labels))
                }
                for change in record.labelsRemoved {
                    let id = change.message.id.number
                    let current = Set(change.message.labelIDs)
                    let leftSpamOrBin = change.labelIDs.contains(.spam) || change.labelIDs.contains(.trash)
                    if leftSpamOrBin, !current.contains(.spam), !current.contains(.trash) {
                        // Back in All Mail: present again if archived, queued if not.
                        states[.present, default: []].append(id)
                        added[id] = change.message.threadID.number
                    }
                    changes.append(Self.copyChange(id, added: [], removed: change.labelIDs, labels: labels))
                }
            }
            report.flagsUpdated += try await state.applyGmailChanges(account.id, changes, at: now())
            for sourceState in [SourceState.present, .spam, .trashed, .gone] {
                guard let ids = states[sourceState], !ids.isEmpty else { continue }
                let changed = try await state.setGmailSourceStates(account.id, ids: ids, sourceState, at: now())
                if sourceState != .present, changed > 0 { report.sourceChanges[sourceState, default: 0] += changed }
            }
            if !added.isEmpty {
                let sort = try await state.sortGmailListing(account.id, ids: added.keys.sorted(), at: now())
                var queued: [GmailQueuedMessage] = []
                for id in sort.new {
                    if let message = try await describe(id, thread: added[id]) { queued.append(message) }
                }
                report.queued += try await state.enqueueGmail(account.id, queued)
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        try await state.gmailHistoryRead(account.id, historyID: newest, at: now())
    }

    /// Labels and flags a history label change means for an archived copy.
    static func copyChange(_ id: UInt64, added: [GmailLabelID], removed: [GmailLabelID], labels: [String: String]) -> GmailCopyChange {
        func has(_ ids: [GmailLabelID], _ name: String) -> Bool { ids.contains { $0.rawValue == name } }
        return GmailCopyChange(
            gmailID: id,
            addLabels: labelNames(added, labels),
            removeLabels: labelNames(removed, labels),
            addFlags: (has(removed, "UNREAD") ? ["\\Seen"] : []) + (has(added, "STARRED") ? ["\\Flagged"] : []),
            removeFlags: (has(added, "UNREAD") ? ["\\Seen"] : []) + (has(removed, "STARRED") ? ["\\Flagged"] : [])
        )
    }

    /// The full check (D-038, D-039): lists every ID in All Mail again (queuing
    /// anything missed and putting back anything that returned), then classifies
    /// archived messages Gmail no longer lists there by looking up the IDs in
    /// Spam and Bin. IDs only, never content.
    private func fullCheck(historyID: UInt64, options: SyncOptions, report: inout SyncReport,
                           onEvent: @Sendable (SyncEvent) -> Void) async throws {
        let archived = try await state.gmailArchivedIDs(account.id)
        let listed = ListedIDs()
        let finished = try await list(historyID: historyID, options: SyncOptions(), report: &report) { listed.add($0) }
        guard finished else { return }
        let missing = archived.subtracting(listed.ids)
        var removed = 0
        if !missing.isEmpty {
            let spam = try await ids(labeled: .spam)
            let trash = try await ids(labeled: .trash)
            var byState: [SourceState: [UInt64]] = [:]
            for id in missing {
                byState[spam.contains(id) ? .spam : trash.contains(id) ? .trashed : .gone, default: []].append(id)
            }
            for (sourceState, ids) in byState {
                let changed = try await state.setGmailSourceStates(account.id, ids: ids.sorted(), sourceState, at: now())
                if changed > 0 { report.sourceChanges[sourceState, default: 0] += changed }
                removed += changed
            }
        }
        try await state.gmailFullChecked(account.id, at: now())
        onEvent(.changesChecked(flagsUpdated: report.flagsUpdated, removedAtSource: removed))
    }

    /// Every message ID carrying a label, Spam and Bin included in the search.
    private func ids(labeled label: GmailLabelID) async throws -> Set<UInt64> {
        var found = Set<UInt64>()
        var pageToken: String?
        repeat {
            let page = try await client.messages(GmailMessageListQuery(labelIDs: [label], includeSpamTrash: true, pageToken: pageToken))
            found.formUnion(page.messages.map(\.id.number))
            pageToken = page.nextPageToken
        } while pageToken != nil
        return found
    }
}

/// IDs a listing saw, collected page by page.
private final class ListedIDs {
    private(set) var ids = Set<UInt64>()
    func add(_ more: Set<UInt64>) { ids.formUnion(more) }
}
