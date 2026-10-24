import Foundation
import Logging
import StowCore

/// Options for one sync run.
public struct SyncOptions: Sendable {
    /// Stop after this many messages in total (across folders). Nil for no limit.
    public var limit: Int?
    public var batches: BatchPlanner
    /// UIDs listed per listing command, so a huge folder is walked in pieces.
    public var listWindow: UInt32
    /// Messages per header-fields fetch when ordering downloads (D-028).
    public var headerChunk: Int
    /// How a batch that came back partial is retried within the run before the
    /// messages are left for the next run (D-118): each round waits, then
    /// re-fetches the still-missing UIDs in chunks of the given size.
    public var partialRetry: [PartialRetryRound]
    /// Stop after the batch in progress once this time has passed, so the
    /// scheduler can give the next account a turn (D-036).
    public var deadline: Date?
    /// Whether to compare archived copies with the server once nothing is left
    /// to download (D-038, D-039).
    public var checkChanges: ChangeCheck

    public init(
        limit: Int? = nil,
        batches: BatchPlanner = BatchPlanner(),
        listWindow: UInt32 = 50_000,
        headerChunk: Int = 500,
        partialRetry: [PartialRetryRound] = PartialRetryRound.default,
        deadline: Date? = nil,
        checkChanges: ChangeCheck = .skip
    ) {
        self.limit = limit
        self.batches = batches
        self.listWindow = max(1, listWindow)
        self.headerChunk = max(1, headerChunk)
        self.partialRetry = partialRetry
        self.deadline = deadline
        self.checkChanges = checkChanges
    }
}

/// How much of the archived mail to compare with the server in a run.
public enum ChangeCheck: Sendable, Equatable {
    case skip
    /// Flags and labels changed since the last check, where the server offers
    /// CONDSTORE; nothing otherwise.
    case quick
    /// Every archived copy: flags, labels, and which are no longer on the server.
    case full
}

/// One round of re-fetching UIDs a partial FETCH left out (D-118).
public struct PartialRetryRound: Sendable, Equatable {
    public var delay: TimeInterval
    public var chunkSize: Int

    public init(delay: TimeInterval, chunkSize: Int) {
        self.delay = delay
        self.chunkSize = max(1, chunkSize)
    }

    /// 2 s then up to 10 at a time; 5 s then one at a time.
    public static let `default` = [PartialRetryRound(delay: 2, chunkSize: 10), PartialRetryRound(delay: 5, chunkSize: 1)]
}

/// Progress events, for the CLI to print. They carry no folder names or message content.
public enum SyncEvent: Sendable {
    case connected(attempt: Int)
    case folderPlanned(toSync: Int, skipped: Int)
    /// A folder was listed: `newMessages` were added to the download queue.
    case folderListed(index: Int, of: Int, newMessages: Int)
    case uidValidityChanged(folderIndex: Int, old: UInt32, new: UInt32)
    /// Downloading starts with this much in the account's queue.
    case downloading(queued: Int, bytes: Int64)
    case batchWritten(messages: Int, bytes: Int64)
    /// Listed messages the server did not return this run. They stay queued and
    /// are tried again next run; nothing else waits for them (D-027).
    case notDownloaded(count: Int)
    /// Messages listed but unreturnable on enough separate runs were recorded and passed (D-115).
    case unfetchableRecorded(count: Int)
    /// Archived copies were compared with the server (D-038, D-039).
    case changesChecked(flagsUpdated: Int, removedAtSource: Int)
    case retrying(after: TimeInterval, attempt: Int, reason: String)
}

/// Why a run finished.
public enum SyncOutcome: Sendable, Equatable {
    case complete
    case limitReached
    /// `neededBytes`: the batch that did not fit, so the scheduler can wait just long enough (D-036).
    case budgetExhausted(usedBytes: Int64, limitBytes: Int64, neededBytes: Int64)
    /// The deadline passed; the scheduler will come back to this account (D-036).
    case yielded
}

public struct SyncReport: Sendable, Equatable {
    public var messagesWritten = 0
    public var bytesWritten: Int64 = 0
    public var foldersSynced = 0
    public var uidValidityResets = 0
    /// Messages added to the download queue by listing.
    public var queued = 0
    /// Listed messages the server would not return this run; still queued.
    public var notDownloaded = 0
    /// Messages passed this run because they were listed but unreturnable on
    /// `threshold` separate runs (D-115).
    public var recordedUnfetchable = 0
    /// The account's queue when the run ended.
    public var remaining = QueueTotals()
    /// Archived copies whose flags or labels were brought up to date.
    public var flagsUpdated = 0
    /// Archived messages found to be gone from where sync looks, and what became of them.
    public var sourceChanges: [SourceState: Int] = [:]
    public var outcome: SyncOutcome = .complete
}

/// Downloads every message of one account into a `RawMessageSink`, keeping
/// its progress in a `SyncStateStore` (Phase 2 steps 4 to 7).
///
/// A run has four parts:
/// 1. **List.** For each folder: EXAMINE, compare UIDVALIDITY, and list the
///    UIDs above the ones already listed, with their sizes, dates and (when a
///    prioritiser is given) the header fields the rules read. Each window of
///    listing goes into the download queue in one step.
/// 2. **Download.** Take the best-priority messages from the queue, in batches,
///    write them to the sink, flush, and only then take them off the queue. A
///    crash can repeat a download but never lose one. Messages the server lists
///    but does not return stay queued; nothing else waits for them (D-027).
/// 3. **Walk.** Mark each folder synced, and its first sync done once nothing
///    is queued for it.
/// 4. **Changes.** When nothing is left to download, compare archived copies
///    with the server: flags and labels, and messages that left a folder,
///    classified as spam, trashed or gone (D-022, D-038, D-039). Nothing is ever
///    deleted from the archive because of it.
public struct AccountSyncer: Sendable {
    public let account: Account
    let openSession: @Sendable () async throws -> IMAPSession
    let sink: RawMessageSink
    let state: SyncStateStore
    let budget: ByteBudget
    let prioritiser: DownloadPrioritiser?
    let unfetchableThreshold: Int
    let retry: RetryPolicy
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let now: @Sendable () -> Date
    private let logger = Logger(label: "ee.getstow.sync.account")

    public static let defaultUnfetchableThreshold = 3

    public init(
        account: Account,
        openSession: @escaping @Sendable () async throws -> IMAPSession,
        sink: RawMessageSink,
        state: SyncStateStore,
        budget: ByteBudget,
        prioritiser: DownloadPrioritiser? = nil,
        unfetchableThreshold: Int = AccountSyncer.defaultUnfetchableThreshold,
        retry: RetryPolicy = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.openSession = openSession
        self.sink = sink
        self.state = state
        self.budget = budget
        self.prioritiser = prioritiser
        self.unfetchableThreshold = max(1, unfetchableThreshold)
        self.retry = retry
        self.sleep = sleep
        self.now = now
    }

    var gmail: Bool { account.provider == .gmail }

    /// Runs until everything is downloaded, the limit, budget or deadline is
    /// reached, or a non-retryable error occurs. Retryable failures reconnect with back-off.
    public func run(_ options: SyncOptions = SyncOptions(), onEvent: @escaping @Sendable (SyncEvent) -> Void = { _ in }) async throws -> SyncReport {
        var report = SyncReport()
        // Identifies this run, so a reconnect within it never counts as a second attempt (D-115).
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
                let delay = retry.delay(forAttempt: failuresWithoutProgress)
                logger.notice("Sync interrupted; will reconnect", metadata: [
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

    /// A folder opened in this run, with what EXAMINE said.
    struct OpenedFolder {
        var folder: IMAPFolder
        var index: Int
        var status: FolderStatus
    }

    private func runOnce(_ options: SyncOptions, runID: String, report: inout SyncReport, attempt: Int, onEvent: @Sendable (SyncEvent) -> Void) async throws {
        let session = try await openSession()
        onEvent(.connected(attempt: attempt))
        do {
            let capabilities = try await session.capabilities()
            let condstore = capabilities.contains("CONDSTORE")
            let listed = try await session.listFolders()
            let plan = try FolderPlanner.plan(provider: account.provider, folders: listed, capabilities: capabilities)
            try await state.recordFolders(account.id, plan.toSync.map { $0.syncFolder(skippedReason: nil) }
                + plan.skipped.map { $0.folder.syncFolder(skippedReason: $0.reason) })
            onEvent(.folderPlanned(toSync: plan.toSync.count, skipped: plan.skipped.count))

            // 1. List what is new in every folder.
            report.foldersSynced = 0
            var opened: [String: OpenedFolder] = [:]
            var current: String?
            for (index, folder) in plan.toSync.enumerated() {
                guard let status = try await examine(folder, condstore: condstore, session: session) else { continue }
                current = folder.name
                opened[folder.name] = OpenedFolder(folder: folder, index: index, status: status)
                if let old = try await state.beginFolder(account.id, folder: folder.name, uidValidity: status.uidValidity, exists: status.exists) {
                    // Every UID in the folder changed meaning: it is listed again from the start.
                    logger.notice("UIDVALIDITY changed; listing folder again", metadata: [
                        "account": "\(account.id)", "old": "\(old)", "new": "\(status.uidValidity)",
                    ])
                    report.uidValidityResets += 1
                    onEvent(.uidValidityChanged(folderIndex: index, old: old, new: status.uidValidity))
                }
                let queued = try await list(folder, status: status, session: session, options: options)
                report.queued += queued
                report.foldersSynced += 1
                onEvent(.folderListed(index: index, of: plan.toSync.count, newMessages: queued))
            }

            // 2. Download from the queue, best priority first.
            let totals = try await state.queueTotals(account.id)
            if totals.queued > 0 { onEvent(.downloading(queued: totals.queued, bytes: totals.queuedBytes)) }
            report.outcome = try await download(opened: opened, current: &current, session: session, options: options,
                                                runID: runID, report: &report, onEvent: onEvent)

            // 3. Record the walk.
            for (name, folder) in opened {
                try await state.folderWalked(account.id, folder: name, uidValidity: folder.status.uidValidity, at: now())
            }

            // 4. Compare archived copies with the server, once nothing is waiting.
            if report.outcome == .complete, options.checkChanges != .skip, try await state.queueTotals(account.id).queued == 0 {
                try await checkChanges(options.checkChanges, plan: plan, listed: listed, opened: opened, condstore: condstore,
                                       session: session, report: &report, onEvent: onEvent)
            }
            await session.logout()
        } catch {
            await session.disconnect()
            throw error
        }
    }

    /// EXAMINE, recording a folder the server refuses to open as that folder's
    /// error (for example one deleted between LIST and EXAMINE) instead of
    /// stopping the whole account.
    private func examine(_ folder: IMAPFolder, condstore: Bool, session: IMAPSession) async throws -> FolderStatus? {
        do {
            let status = try await session.examine(folder, condstore: condstore)
            return status
        } catch SyncError.commandFailed(let command, let status, let text) {
            let message = "\(command) failed (\(status)): \(text)"
            logger.warning("Folder could not be opened", metadata: ["account": "\(account.id)", "error": "\(message)"])
            try await state.setFolderError(account.id, folder: folder.name, error: message)
            return nil
        }
    }

    // MARK: - 1. Listing

    /// Lists every UID above what was listed before and queues it. Returns how many were queued.
    private func list(_ folder: IMAPFolder, status: FolderStatus, session: IMAPSession, options: SyncOptions) async throws -> Int {
        let listedThrough = try await state.folderState(account.id, folder: folder.name)?.listedThroughUID ?? 0
        // The highest UID that can exist now is UIDNEXT - 1. Without UIDNEXT, list to the end in one go.
        let upper: UInt32 = status.uidNext.map { $0 > 0 ? $0 - 1 : 0 } ?? UInt32.max
        guard status.exists > 0, listedThrough < upper else { return 0 }

        let window = status.uidNext == nil ? UInt32.max : options.listWindow
        var queued = 0
        var windowStart = listedThrough + 1
        while windowStart <= upper {
            let windowEnd = upper - windowStart < window ? upper : windowStart + window - 1
            let summaries = try await session.fetchUIDs(windowStart...windowEnd, gmail: gmail)
            var priorities: [UInt32: Int] = [:]
            if let prioritiser, !summaries.isEmpty {
                for start in stride(from: 0, to: summaries.count, by: options.headerChunk) {
                    let chunk = summaries[start..<min(start + options.headerChunk, summaries.count)].map(\.uid)
                    for (uid, fields) in try await session.fetchHeaderFields(uids: chunk, fields: PriorityHeaderFields.names) {
                        priorities[uid] = prioritiser(fields)
                    }
                }
            }
            let messages = summaries.map {
                QueuedMessage(folder: folder.name, uidValidity: status.uidValidity, uid: $0.uid, size: $0.size,
                              internalDate: $0.internalDate, priority: priorities[$0.uid] ?? 0, gmailMessageID: $0.gmailMessageID)
            }
            // Without UIDNEXT the window ran to the end, so the highest UID seen is the honest mark.
            let through = windowEnd == UInt32.max ? (summaries.last?.uid ?? listedThrough) : windowEnd
            queued += try await state.enqueue(account.id, folder: folder.name, uidValidity: status.uidValidity,
                                              messages: messages, listedThrough: through)
            if windowEnd == UInt32.max { break }
            windowStart = windowEnd + 1
        }
        return queued
    }

    // MARK: - 2. Downloading

    private func download(
        opened: [String: OpenedFolder], current: inout String?, session: IMAPSession, options: SyncOptions,
        runID: String, report: inout SyncReport, onEvent: @Sendable (SyncEvent) -> Void
    ) async throws -> SyncOutcome {
        var batches = 0
        while true {
            if let limit = options.limit, report.messagesWritten >= limit { return .limitReached }
            // At least one batch per turn, so a slow listing can never starve the downloads.
            if batches > 0, let deadline = options.deadline, now() >= deadline { return .yielded }
            batches += 1
            let room = options.limit.map { $0 - report.messagesWritten } ?? options.batches.maxMessages
            let batch = try await state.nextDownloads(account.id, runID: runID, maxMessages: min(room, options.batches.maxMessages),
                                                      maxBytes: options.batches.maxBytes)
            guard let first = batch.first else { return .complete }
            let uids = batch.map(\.uid)

            // Queued for a folder not opened this run (gone, or no longer synced),
            // or for an old UIDVALIDITY: those UIDs mean nothing any more.
            guard let folder = opened[first.folder], folder.status.uidValidity == first.uidValidity else {
                try await state.vanishedBeforeDownload(account.id, folder: first.folder, uidValidity: first.uidValidity, uids: uids)
                continue
            }
            if current != first.folder {
                let status = try await session.examine(folder.folder)
                guard status.uidValidity == first.uidValidity else {
                    throw SyncError.protocolViolation("UIDVALIDITY changed during the run")
                }
                current = first.folder
            }

            let planned = Int64(batch.reduce(0) { $0 + $1.size })
            guard try await budget.allows(planned) else {
                return .budgetExhausted(usedBytes: try await budget.used(), limitBytes: budget.limit ?? 0, neededBytes: planned)
            }
            let messages = try await fetchRetryingPartial(uids, session: session, options: options, folderIndex: folder.index)
            var bytes: Int64 = 0
            for message in messages {
                try await sink.write(RawMessage(
                    key: RawMessageKey(accountID: account.id, folder: first.folder, uidValidity: first.uidValidity, uid: message.uid),
                    labels: message.labels,
                    gmailMessageID: message.gmailMessageID,
                    gmailThreadID: message.gmailThreadID,
                    internalDate: message.internalDate,
                    size: message.size,
                    flags: message.flags,
                    bytes: message.bytes
                ))
                bytes += Int64(message.bytes.count)
            }
            // Durable first, then off the queue: a crash can repeat a download but never lose one.
            try await sink.flush()
            let written = Set(messages.map(\.uid))
            try await state.downloaded(account.id, folder: first.folder, uidValidity: first.uidValidity, uids: written.sorted())

            // Listed but not returned: ask again whether they still exist (D-113).
            let missing = uids.filter { !written.contains($0) }
            if !missing.isEmpty {
                let relisted = try await session.fetchUIDs(missing)
                let gone = Set(missing).subtracting(relisted.map(\.uid))
                if !gone.isEmpty {
                    try await state.vanishedBeforeDownload(account.id, folder: first.folder, uidValidity: first.uidValidity, uids: gone.sorted())
                    logger.notice("Listed messages were deleted on the server before download", metadata: [
                        "account": "\(account.id)", "count": "\(gone.count)",
                    ])
                }
                if !relisted.isEmpty {
                    // Still listed but not returned: count an attempt; after enough
                    // separate runs they are recorded and passed (D-115).
                    let recorded = try await state.recordFailedAttempt(
                        account.id, folder: first.folder, uidValidity: first.uidValidity, runID: runID,
                        failed: relisted.map { FailedDownload(uid: $0.uid, flags: $0.flags) }, threshold: unfetchableThreshold)
                    let stuck = relisted.count - recorded.count
                    report.recordedUnfetchable += recorded.count
                    report.notDownloaded += stuck
                    if !recorded.isEmpty {
                        logger.warning("Passed messages the server never returns, after repeated runs", metadata: [
                            "account": "\(account.id)", "folderIndex": "\(folder.index)", "count": "\(recorded.count)",
                        ])
                        onEvent(.unfetchableRecorded(count: recorded.count))
                    }
                    if stuck > 0 {
                        logger.error("Server listed messages it would not return; left queued for the next run", metadata: [
                            "account": "\(account.id)", "folderIndex": "\(folder.index)", "count": "\(stuck)",
                        ])
                        onEvent(.notDownloaded(count: stuck))
                    }
                }
            }
            try await budget.record(bytes)
            report.messagesWritten += messages.count
            report.bytesWritten += bytes
            onEvent(.batchWritten(messages: messages.count, bytes: bytes))
        }
    }

    /// Fetches a batch. If the server leaves some UIDs out, waits and re-fetches
    /// just those in smaller chunks, as `options.partialRetry` says, logging what
    /// the server said each time (D-118). Whatever is still missing afterwards
    /// is left to the D-113 and D-115 handling.
    private func fetchRetryingPartial(_ uids: [UInt32], session: IMAPSession, options: SyncOptions, folderIndex: Int) async throws -> [FetchedMessage] {
        let first = try await session.fetchMessagesWithDiagnostics(uids: uids, gmail: gmail)
        var messages = checked(first.messages, folderIndex: folderIndex)
        var missing = Self.missing(uids, from: messages)
        guard !missing.isEmpty else { return messages }
        logPartial(first.diagnostics, folderIndex: folderIndex, round: 0, asked: uids.count, returned: messages.count)

        for (number, round) in options.partialRetry.enumerated() where !missing.isEmpty {
            do {
                try await sleep(round.delay)
            } catch {
                throw SyncError.cancelled
            }
            for start in stride(from: 0, to: missing.count, by: round.chunkSize) {
                let chunk = Array(missing[start..<min(start + round.chunkSize, missing.count)])
                let reply = try await session.fetchMessagesWithDiagnostics(uids: chunk, gmail: gmail)
                let accepted = checked(reply.messages, folderIndex: folderIndex)
                messages += accepted
                if accepted.count < chunk.count {
                    logPartial(reply.diagnostics, folderIndex: folderIndex, round: number + 1, asked: chunk.count, returned: accepted.count)
                }
            }
            missing = Self.missing(uids, from: messages)
        }
        logger.notice("Partial FETCH retried within the run", metadata: [
            "account": "\(account.id)", "folderIndex": "\(folderIndex)", "asked": "\(uids.count)",
            "returnedFirstTime": "\(first.messages.count)", "stillMissing": "\(missing.count)",
        ])
        return messages
    }

    /// Passes every message through. RFC822.SIZE is not an integrity check:
    /// Exchange reports an estimate (D-120). The exact check, each body against
    /// its literal's announced length, happens in `IMAPSession`. Disagreements
    /// with RFC822.SIZE are only counted, at debug level, as a provider signal.
    private func checked(_ messages: [FetchedMessage], folderIndex: Int) -> [FetchedMessage] {
        let differing = messages.filter { $0.bytes.count != $0.size }.count
        if differing > 0 {
            logger.debug("RFC822.SIZE differs from the downloaded length", metadata: [
                "account": "\(account.id)", "folderIndex": "\(folderIndex)",
                "messages": "\(messages.count)", "differing": "\(differing)",
            ])
        }
        return messages
    }

    static func missing(_ uids: [UInt32], from messages: [FetchedMessage]) -> [UInt32] {
        let got = Set(messages.map(\.uid))
        return uids.filter { !got.contains($0) }
    }

    /// Notice-level record of how the server completed a partial FETCH. Counts,
    /// status, response code and scrubbed server text only: no content, no addresses.
    private func logPartial(_ diagnostics: FetchDiagnostics, folderIndex: Int, round: Int, asked: Int, returned: Int) {
        logger.notice("Partial FETCH reply", metadata: [
            "account": "\(account.id)", "folderIndex": "\(folderIndex)", "round": "\(round)",
            "asked": "\(asked)", "returned": "\(returned)",
            "status": "\(diagnostics.status)", "code": "\(diagnostics.code ?? "none")",
            "text": "\(diagnostics.text)", "untagged": "\(diagnostics.untagged.joined(separator: " | "))",
        ])
    }

    // MARK: - 4. Changes at the source

    private func checkChanges(
        _ mode: ChangeCheck, plan: FolderPlan, listed: [IMAPFolder], opened: [String: OpenedFolder], condstore: Bool,
        session: IMAPSession, report: inout SyncReport, onEvent: @Sendable (SyncEvent) -> Void
    ) async throws {
        var vanished: [VanishedMessage] = []
        var flagsUpdated = 0
        let at = now()

        if mode == .full {
            // A folder synced before but no longer listed at all was deleted (or renamed) on the server.
            let listedNames = Set(listed.map(\.name))
            for name in try await state.syncedFolders(account.id) where !listedNames.contains(name) {
                guard let saved = try await state.folderState(account.id, folder: name) else { continue }
                let stored = try await state.storedUIDs(account.id, folder: name, uidValidity: saved.uidValidity)
                vanished += try await state.markRemovedFromServer(account.id, folder: name, uidValidity: saved.uidValidity, uids: stored, at: at)
                let queued = try await state.queuedUIDs(account.id, folder: name, uidValidity: saved.uidValidity)
                try await state.vanishedBeforeDownload(account.id, folder: name, uidValidity: saved.uidValidity, uids: queued)
            }
        }

        for folder in plan.toSync {
            guard let open = opened[folder.name],
                  let saved = try await state.folderState(account.id, folder: folder.name),
                  saved.uidValidity == open.status.uidValidity, saved.listedThroughUID > 0
            else { continue }
            let range = 1...saved.listedThroughUID
            switch mode {
            case .skip:
                break
            case .quick:
                // Only with CONDSTORE, and only when something changed since the last check.
                guard condstore, let since = saved.highestModSeq, let current = open.status.highestModSeq, current > since else { continue }
                _ = try await session.examine(folder, condstore: true)
                let states = try await session.fetchStates(range, gmail: gmail, changedSince: since)
                try await state.applyCopyStates(account.id, folder: folder.name, uidValidity: saved.uidValidity, states, at: at)
                flagsUpdated += states.count
                try await state.folderChecked(account.id, folder: folder.name, uidValidity: saved.uidValidity,
                                              highestModSeq: current, fullCheck: false, at: at)
            case .full:
                let status = try await session.examine(folder, condstore: condstore)
                let states = try await session.fetchStates(range, gmail: gmail)
                var present = Set(states.map(\.uid))
                let stored = try await state.storedUIDs(account.id, folder: folder.name, uidValidity: saved.uidValidity)
                let storedSet = Set(stored)
                let changed = states.filter { storedSet.contains($0.uid) }
                try await state.applyCopyStates(account.id, folder: folder.name, uidValidity: saved.uidValidity, changed, at: at)
                flagsUpdated += changed.count
                // A server can leave messages out of a large reply (D-118): only
                // messages that a second, specific listing also lacks count as gone.
                var absent = stored.filter { !present.contains($0) }
                let queued = try await state.queuedUIDs(account.id, folder: folder.name, uidValidity: saved.uidValidity)
                let absentQueued = queued.filter { !present.contains($0) }
                let recheck = absent + absentQueued
                if !recheck.isEmpty {
                    present.formUnion(try await session.fetchUIDs(recheck).map(\.uid))
                    absent = absent.filter { !present.contains($0) }
                }
                vanished += try await state.markRemovedFromServer(account.id, folder: folder.name, uidValidity: saved.uidValidity,
                                                                 uids: absent, at: at)
                try await state.vanishedBeforeDownload(account.id, folder: folder.name, uidValidity: saved.uidValidity,
                                                       uids: absentQueued.filter { !present.contains($0) })
                try await state.folderChecked(account.id, folder: folder.name, uidValidity: saved.uidValidity,
                                              highestModSeq: status.highestModSeq, fullCheck: true, at: at)
            }
        }

        if !vanished.isEmpty {
            let classified = try await classify(vanished, folders: listed, session: session)
            try await state.setSourceStates(account.id, classified, at: at)
            for (_, sourceState) in classified { report.sourceChanges[sourceState, default: 0] += 1 }
        }
        report.flagsUpdated += flagsUpdated
        onEvent(.changesChecked(flagsUpdated: flagsUpdated, removedAtSource: vanished.count))
        if !vanished.isEmpty {
            logger.notice("Archived messages no longer in the mailbox; kept in the archive", metadata: [
                "account": "\(account.id)", "count": "\(vanished.count)",
            ])
        }
    }

    /// Spam, trashed or gone, for messages no longer anywhere sync looks (D-039).
    /// Gmail: their message IDs are looked for in Spam and Bin. Microsoft: their
    /// Message-IDs are looked for in Junk (Deleted Items is synced, so trashed
    /// messages never get here). Only identifiers are fetched from those
    /// folders, never content.
    private func classify(_ vanished: [VanishedMessage], folders: [IMAPFolder], session: IMAPSession) async throws -> [Int64: SourceState] {
        var result: [Int64: SourceState] = [:]
        if gmail {
            let spam = try await gmailIDs(in: folders.first { $0.has("\\Junk") && $0.isSelectable }, session: session)
            let trash = try await gmailIDs(in: folders.first { $0.has("\\Trash") && $0.isSelectable }, session: session)
            for message in vanished {
                guard let id = message.gmailMessageID else { result[message.messageID] = .gone; continue }
                result[message.messageID] = spam.contains(id) ? .spam : trash.contains(id) ? .trashed : .gone
            }
        } else {
            var junkIDs: Set<String> = []
            if let junk = folders.first(where: { $0.has("\\Junk") && $0.isSelectable }),
               vanished.contains(where: { $0.rfc822MessageID != nil }) {
                let status = try await session.examine(junk)
                if status.exists > 0 {
                    let upper = status.uidNext.map { max($0, 2) - 1 } ?? UInt32.max
                    for fields in try await session.fetchHeaderFields(1...upper, fields: ["Message-ID"]).values {
                        if let id = HeaderParser().parseHeaders(fields).messageID { junkIDs.insert(id) }
                    }
                }
            }
            for message in vanished {
                result[message.messageID] = message.rfc822MessageID.map(junkIDs.contains) == true ? .spam : .gone
            }
        }
        return result
    }

    private func gmailIDs(in folder: IMAPFolder?, session: IMAPSession) async throws -> Set<UInt64> {
        guard let folder else { return [] }
        let status = try await session.examine(folder)
        guard status.exists > 0 else { return [] }
        let upper = status.uidNext.map { max($0, 2) - 1 } ?? UInt32.max
        return try await session.fetchGmailIDs(1...upper)
    }
}
