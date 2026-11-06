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
/// Changes after the listing (`history.list`, D-038, D-039) are step 5.
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

        // 1. List, until a full listing has finished once.
        var listingDone = try await state.gmailState(account.id)?.fullListingCompletedAt != nil
        if !listingDone {
            try await state.beginGmailSync(account.id)
            let finished = try await list(historyID: profile.historyID, options: options, report: &report)
            listingDone = finished
            onEvent(.folderListed(index: 0, of: 1, newMessages: report.queued))
        }
        report.foldersSynced = 1
        if options.listOnly { return }

        // 2. Download from the queue, best priority first.
        let totals = try await state.queueTotals(account.id)
        if totals.queued > 0 { onEvent(.downloading(queued: totals.queued, bytes: totals.queuedBytes)) }
        report.outcome = try await download(allMail: allMail, options: options, runID: runID, report: &report, onEvent: onEvent)
        if listingDone { try await state.gmailQueueChecked(account.id, at: now()) }
    }

    // MARK: - 1. Listing

    /// Pages through All Mail without Spam and Bin. Returns whether the listing
    /// reached its last page; a deadline stops it between pages.
    private func list(historyID: UInt64, options: SyncOptions, report: inout SyncReport) async throws -> Bool {
        var pageToken: String?
        repeat {
            let page = try await client.messages(GmailMessageListQuery(includeSpamTrash: false, pageToken: pageToken))
            let sort = try await state.sortGmailListing(account.id, ids: page.messages.map(\.id.number), at: now())
            if sort.adopted > 0 {
                logger.info("Adopted messages archived before", metadata: ["account": "\(account.id)", "count": "\(sort.adopted)"])
            }
            let threads = Dictionary(page.messages.map { ($0.id.number, $0.threadID.number) }, uniquingKeysWith: { first, _ in first })
            var queued: [GmailQueuedMessage] = []
            for id in sort.new {
                if let message = try await describe(id, thread: threads[id]) { queued.append(message) }
            }
            report.queued += try await state.enqueueGmail(account.id, queued)
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

    private func download(allMail: String, options: SyncOptions, runID: String, report: inout SyncReport,
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
            for queued in batch {
                let message: GmailMessage
                do {
                    message = try await client.message(GmailMessageID(number: queued.gmailID), format: .raw)
                } catch is GmailNotFound {
                    gone.append(queued.gmailID)
                    continue
                } catch SyncError.protocolViolation, SyncError.commandFailed {
                    // This message's reply was unusable; others carry on (D-113).
                    failed.append(queued.gmailID)
                    continue
                }
                guard let raw = message.raw else { failed.append(queued.gmailID); continue }
                try await sink.write(RawMessage(
                    key: .gmailAPI(accountID: account.id, allMail: allMail),
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
        }
    }

    /// Gmail's read and starred state as the IMAP flags Gmail sync always
    /// stored, so a message looks the same whichever way it arrived:
    /// no `UNREAD` label is `\Seen`, `STARRED` is `\Flagged`. Labels themselves
    /// are step 4.
    static func flags(_ labels: [GmailLabelID]) -> [String] {
        let names = Set(labels.map(\.rawValue))
        var flags: [String] = []
        if names.contains("STARRED") { flags.append("\\Flagged") }
        if !names.contains("UNREAD") { flags.append("\\Seen") }
        return flags
    }
}
