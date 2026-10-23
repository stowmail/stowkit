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
    /// How a batch that came back partial is retried within the run before the
    /// folder stops (D-118): each round waits, then re-fetches the still-missing
    /// UIDs in chunks of the given size.
    public var partialRetry: [PartialRetryRound]

    public init(
        limit: Int? = nil,
        batches: BatchPlanner = BatchPlanner(),
        listWindow: UInt32 = 50_000,
        partialRetry: [PartialRetryRound] = PartialRetryRound.default
    ) {
        self.limit = limit
        self.batches = batches
        self.listWindow = max(1, listWindow)
        self.partialRetry = partialRetry
    }
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
    case folderStarted(index: Int, of: Int, newMessages: Int)
    case uidValidityChanged(folderIndex: Int, old: UInt32, new: UInt32)
    case batchWritten(messages: Int, bytes: Int64, highestUID: UInt32)
    /// Some listed messages could not be downloaded and are still on the server.
    /// The folder stops before them; its checkpoint does not pass them (D-113).
    case folderStopped(index: Int, notDownloaded: Int)
    /// Messages listed but unreturnable on enough separate runs were recorded and passed (D-115).
    case unfetchableRecorded(index: Int, count: Int)
    case retrying(after: TimeInterval, attempt: Int, reason: String)
}

/// Why a run finished.
public enum SyncOutcome: Sendable, Equatable {
    case complete
    case limitReached
    case budgetExhausted(usedBytes: Int64, limitBytes: Int64)
}

public struct SyncReport: Sendable, Equatable {
    public var messagesWritten = 0
    public var bytesWritten: Int64 = 0
    public var foldersSynced = 0
    public var uidValidityResets = 0
    /// Messages the server listed but would not return, per folder index (D-113).
    /// Non-empty means the run is incomplete, even if `outcome` is `.complete`.
    public var notDownloaded: [Int: Int] = [:]
    /// Messages passed this run because they were listed but unreturnable on
    /// `UnfetchableLedger.threshold` separate runs, per folder index (D-115).
    public var recordedUnfetchable: [Int: Int] = [:]
    public var outcome: SyncOutcome = .complete
}

/// Downloads every message of one account into a `RawMessageSink`, resuming
/// from checkpoints (brief steps 3 to 5).
///
/// For each folder: EXAMINE, compare UIDVALIDITY with the checkpoint, list
/// what is newer than the checkpoint, then fetch in batches. After each batch
/// is written and flushed, the checkpoint moves to the highest UID below which
/// every listed message was either written or confirmed gone from the server
/// (D-113). A crash therefore repeats at most one batch (the sink ignores the
/// repeats) and never skips one.
public struct AccountSyncer: Sendable {
    public let account: Account
    let openSession: @Sendable () async throws -> IMAPSession
    let sink: RawMessageSink
    let checkpoints: SyncCheckpointStore
    let budget: ByteBudget
    let unfetchable: UnfetchableLedger
    let retry: RetryPolicy
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.getstow.sync.account")

    public init(
        account: Account,
        openSession: @escaping @Sendable () async throws -> IMAPSession,
        sink: RawMessageSink,
        checkpoints: SyncCheckpointStore,
        budget: ByteBudget,
        unfetchable: UnfetchableLedger = UnfetchableLedger(fileURL: nil),
        retry: RetryPolicy = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.openSession = openSession
        self.sink = sink
        self.checkpoints = checkpoints
        self.budget = budget
        self.unfetchable = unfetchable
        self.retry = retry
        self.sleep = sleep
        self.now = now
    }

    /// Runs until everything is downloaded, the limit or budget is reached, or
    /// a non-retryable error occurs. Retryable failures reconnect with back-off.
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

    private func runOnce(_ options: SyncOptions, runID: String, report: inout SyncReport, attempt: Int, onEvent: @Sendable (SyncEvent) -> Void) async throws {
        let session = try await openSession()
        onEvent(.connected(attempt: attempt))
        do {
            let capabilities = try await session.capabilities()
            let plan = try FolderPlanner.plan(provider: account.provider, folders: try await session.listFolders(), capabilities: capabilities)
            onEvent(.folderPlanned(toSync: plan.toSync.count, skipped: plan.skipped.count))
            report.foldersSynced = 0
            for (index, folder) in plan.toSync.enumerated() {
                let outcome = try await syncFolder(folder, index: index, of: plan.toSync.count, session: session, options: options, runID: runID, report: &report, onEvent: onEvent)
                report.foldersSynced += 1
                if outcome != .complete {
                    report.outcome = outcome
                    break
                }
            }
            await session.logout()
        } catch {
            await session.disconnect()
            throw error
        }
    }

    private func syncFolder(
        _ folder: IMAPFolder,
        index: Int,
        of total: Int,
        session: IMAPSession,
        options: SyncOptions,
        runID: String,
        report: inout SyncReport,
        onEvent: @Sendable (SyncEvent) -> Void
    ) async throws -> SyncOutcome {
        let status = try await session.examine(folder)
        let saved = try await checkpoints.checkpoint(accountID: account.id, folder: folder.name)

        var highestDone: UInt32 = 0
        if let saved {
            if saved.uidValidity == status.uidValidity {
                highestDone = saved.highestUID
            } else {
                // Every UID in the folder changed meaning: start again (brief step 5).
                logger.notice("UIDVALIDITY changed; resyncing folder", metadata: [
                    "account": "\(account.id)", "old": "\(saved.uidValidity)", "new": "\(status.uidValidity)",
                ])
                report.uidValidityResets += 1
                onEvent(.uidValidityChanged(folderIndex: index, old: saved.uidValidity, new: status.uidValidity))
            }
        }
        if saved == nil || saved?.uidValidity != status.uidValidity {
            try await saveCheckpoint(folder: folder, uidValidity: status.uidValidity, highestUID: 0)
        }

        // The highest UID that can exist now is UIDNEXT - 1. Without UIDNEXT, list to the end in one go.
        let upper: UInt32 = status.uidNext.map { $0 > 0 ? $0 - 1 : 0 } ?? UInt32.max
        guard status.exists > 0, highestDone < upper else {
            onEvent(.folderStarted(index: index, of: total, newMessages: 0))
            return .complete
        }

        // List the whole range first (UIDs and sizes only, cheap), so the count
        // announced is right even when the first windows are empty.
        let window = status.uidNext == nil ? UInt32.max : options.listWindow
        var summaries: [MessageSummary] = []
        var windowStart = highestDone + 1
        while windowStart <= upper {
            let windowEnd = upper - windowStart < window ? upper : windowStart + window - 1
            summaries += try await session.fetchUIDs(windowStart...windowEnd)
            if windowEnd == UInt32.max { break }
            windowStart = windowEnd + 1
        }
        onEvent(.folderStarted(index: index, of: total, newMessages: summaries.count))
        if let limit = options.limit {
            let remaining = limit - report.messagesWritten
            if remaining <= 0 { return .limitReached }
            if summaries.count > remaining { summaries = Array(summaries.prefix(remaining)) }
        }

        var checkpointUID = highestDone
        for batch in options.batches.batches(summaries) {
            let planned = Int64(batch.reduce(0) { $0 + $1.size })
            guard await budget.allows(planned) else {
                let used = await budget.used()
                return .budgetExhausted(usedBytes: used, limitBytes: budget.limit ?? 0)
            }
            let messages = try await fetchRetryingPartial(batch.map(\.uid), session: session, options: options, folderIndex: index)
            var bytes: Int64 = 0
            for message in messages {
                try await sink.write(RawMessage(
                    key: RawMessageKey(accountID: account.id, folder: folder.name, uidValidity: status.uidValidity, uid: message.uid),
                    labels: message.labels,
                    gmailMessageID: message.gmailMessageID,
                    gmailThreadID: message.gmailThreadID,
                    internalDate: message.internalDate,
                    size: message.size,
                    bytes: message.bytes
                ))
                bytes += Int64(message.bytes.count)
            }
            // Durable first, then the checkpoint: a crash can repeat a batch but never skip one.
            try await sink.flush()

            // Listed but not returned: ask again whether they still exist (D-113).
            let written = Set(messages.map(\.uid))
            let missing = batch.map(\.uid).filter { !written.contains($0) }
            var gone: Set<UInt32> = []
            var relisted: [MessageSummary] = []
            if !missing.isEmpty {
                relisted = try await session.fetchUIDs(missing)
                gone = Set(missing).subtracting(relisted.map(\.uid))
            }
            // Still listed but not returned: count an attempt; after enough
            // separate runs they are recorded and passed (D-115).
            var recorded: Set<UInt32> = []
            if !relisted.isEmpty {
                recorded = try await unfetchable.recordAttempt(folder: folder.name, uidValidity: status.uidValidity, runID: runID, stuck: relisted)
            }
            try await unfetchable.resolve(folder: folder.name, uidValidity: status.uidValidity, uids: written.union(gone))
            let stuck = missing.filter { !gone.contains($0) && !recorded.contains($0) }
            // Advance only through an unbroken run of written, vanished or recorded UIDs.
            for summary in batch {
                guard written.contains(summary.uid) || gone.contains(summary.uid) || recorded.contains(summary.uid) else { break }
                checkpointUID = summary.uid
            }
            if !recorded.isEmpty {
                report.recordedUnfetchable[index, default: 0] += recorded.count
                logger.warning("Passed messages the server never returns, after repeated runs", metadata: [
                    "account": "\(account.id)", "folderIndex": "\(index)", "count": "\(recorded.count)",
                ])
                onEvent(.unfetchableRecorded(index: index, count: recorded.count))
            }
            try await saveCheckpoint(folder: folder, uidValidity: status.uidValidity, highestUID: checkpointUID)
            try await budget.record(bytes)
            report.messagesWritten += messages.count
            report.bytesWritten += bytes
            onEvent(.batchWritten(messages: messages.count, bytes: bytes, highestUID: checkpointUID))

            if !gone.isEmpty {
                logger.notice("Listed messages were deleted on the server before download", metadata: [
                    "account": "\(account.id)", "count": "\(gone.count)",
                ])
            }
            if !stuck.isEmpty {
                // Still on the server but not downloadable. Stop this folder here so
                // the checkpoint never passes them; report it loudly.
                logger.error("Server listed messages it would not return; folder stopped", metadata: [
                    "account": "\(account.id)", "folderIndex": "\(index)", "count": "\(stuck.count)",
                ])
                report.notDownloaded[index] = stuck.count
                onEvent(.folderStopped(index: index, notDownloaded: stuck.count))
                return .complete
            }
            if let limit = options.limit, report.messagesWritten >= limit { return .limitReached }
        }
        return .complete
    }

    /// Fetches a batch. If the server leaves some UIDs out, waits and re-fetches
    /// just those in smaller chunks, as `options.partialRetry` says, logging what
    /// the server said each time (D-118). Whatever is still missing afterwards
    /// is left to the D-113 and D-115 handling.
    private func fetchRetryingPartial(_ uids: [UInt32], session: IMAPSession, options: SyncOptions, folderIndex: Int) async throws -> [FetchedMessage] {
        let gmail = account.provider == .gmail
        let first = try await session.fetchMessagesWithDiagnostics(uids: uids, gmail: gmail)
        var messages = first.messages
        var missing = Self.missing(uids, from: messages)
        guard !missing.isEmpty else { return messages }
        logPartial(first.diagnostics, folderIndex: folderIndex, round: 0, asked: uids.count, returned: first.messages.count)

        for (number, round) in options.partialRetry.enumerated() where !missing.isEmpty {
            do {
                try await sleep(round.delay)
            } catch {
                throw SyncError.cancelled
            }
            for start in stride(from: 0, to: missing.count, by: round.chunkSize) {
                let chunk = Array(missing[start..<min(start + round.chunkSize, missing.count)])
                let reply = try await session.fetchMessagesWithDiagnostics(uids: chunk, gmail: gmail)
                messages += reply.messages
                if reply.messages.count < chunk.count {
                    logPartial(reply.diagnostics, folderIndex: folderIndex, round: number + 1, asked: chunk.count, returned: reply.messages.count)
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

    private func saveCheckpoint(folder: IMAPFolder, uidValidity: UInt32, highestUID: UInt32) async throws {
        try await checkpoints.save(SyncCheckpoint(
            accountID: account.id, folder: folder.name, uidValidity: uidValidity, highestUID: highestUID, updatedAt: now()
        ))
    }
}
