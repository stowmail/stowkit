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

    public init(limit: Int? = nil, batches: BatchPlanner = BatchPlanner(), listWindow: UInt32 = 50_000) {
        self.limit = limit
        self.batches = batches
        self.listWindow = max(1, listWindow)
    }
}

/// Progress events, for the CLI to print. They carry no folder names or message content.
public enum SyncEvent: Sendable {
    case connected(attempt: Int)
    case folderPlanned(toSync: Int, skipped: Int)
    case folderStarted(index: Int, of: Int, newMessages: Int)
    case uidValidityChanged(folderIndex: Int, old: UInt32, new: UInt32)
    case batchWritten(messages: Int, bytes: Int64, highestUID: UInt32)
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
    public var outcome: SyncOutcome = .complete
}

/// Downloads every message of one account into a `RawMessageSink`, resuming
/// from checkpoints (brief steps 3 to 5).
///
/// For each folder: EXAMINE, compare UIDVALIDITY with the checkpoint, list
/// what is newer than the checkpoint, then fetch in batches. After each batch
/// is written and flushed, the checkpoint moves to the batch's highest UID.
/// A crash therefore repeats at most one batch (the sink ignores the
/// repeats) and never skips one.
public struct AccountSyncer: Sendable {
    public let account: Account
    let openSession: @Sendable () async throws -> IMAPSession
    let sink: RawMessageSink
    let checkpoints: SyncCheckpointStore
    let budget: ByteBudget
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
        retry: RetryPolicy = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.openSession = openSession
        self.sink = sink
        self.checkpoints = checkpoints
        self.budget = budget
        self.retry = retry
        self.sleep = sleep
        self.now = now
    }

    /// Runs until everything is downloaded, the limit or budget is reached, or
    /// a non-retryable error occurs. Retryable failures reconnect with back-off.
    public func run(_ options: SyncOptions = SyncOptions(), onEvent: @escaping @Sendable (SyncEvent) -> Void = { _ in }) async throws -> SyncReport {
        var report = SyncReport()
        var failuresWithoutProgress = 0
        var attempt = 0
        while true {
            attempt += 1
            let before = report.messagesWritten
            do {
                try await runOnce(options, report: &report, attempt: attempt, onEvent: onEvent)
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

    private func runOnce(_ options: SyncOptions, report: inout SyncReport, attempt: Int, onEvent: @Sendable (SyncEvent) -> Void) async throws {
        let session = try await openSession()
        onEvent(.connected(attempt: attempt))
        do {
            let capabilities = try await session.capabilities()
            let plan = try FolderPlanner.plan(provider: account.provider, folders: try await session.listFolders(), capabilities: capabilities)
            onEvent(.folderPlanned(toSync: plan.toSync.count, skipped: plan.skipped.count))
            report.foldersSynced = 0
            for (index, folder) in plan.toSync.enumerated() {
                let outcome = try await syncFolder(folder, index: index, of: plan.toSync.count, session: session, options: options, report: &report, onEvent: onEvent)
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

        let window = status.uidNext == nil ? UInt32.max : options.listWindow
        var windowStart = highestDone + 1
        var announced = false
        while windowStart <= upper {
            let windowEnd = upper - windowStart < window ? upper : windowStart + window - 1
            var summaries = try await session.fetchUIDs(windowStart...windowEnd)
            if !announced {
                onEvent(.folderStarted(index: index, of: total, newMessages: summaries.count))
                announced = true
            }
            if let limit = options.limit {
                let remaining = limit - report.messagesWritten
                if remaining <= 0 { return .limitReached }
                if summaries.count > remaining { summaries = Array(summaries.prefix(remaining)) }
            }
            for batch in options.batches.batches(summaries) {
                let planned = Int64(batch.reduce(0) { $0 + $1.size })
                guard await budget.allows(planned) else {
                    let used = await budget.used()
                    return .budgetExhausted(usedBytes: used, limitBytes: budget.limit ?? 0)
                }
                let messages = try await session.fetchMessages(uids: batch.map(\.uid), gmail: account.provider == .gmail)
                if messages.count != batch.count {
                    // Usually messages deleted on the server since they were listed.
                    logger.notice("Fewer messages fetched than listed", metadata: [
                        "account": "\(account.id)", "listed": "\(batch.count)", "fetched": "\(messages.count)",
                    ])
                }
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
                let highest = batch.last!.uid
                try await saveCheckpoint(folder: folder, uidValidity: status.uidValidity, highestUID: highest)
                try await budget.record(bytes)
                report.messagesWritten += messages.count
                report.bytesWritten += bytes
                onEvent(.batchWritten(messages: messages.count, bytes: bytes, highestUID: highest))
                if let limit = options.limit, report.messagesWritten >= limit { return .limitReached }
            }
            if windowEnd == UInt32.max { break }
            windowStart = windowEnd + 1
        }
        return .complete
    }

    private func saveCheckpoint(folder: IMAPFolder, uidValidity: UInt32, highestUID: UInt32) async throws {
        try await checkpoints.save(SyncCheckpoint(
            accountID: account.id, folder: folder.name, uidValidity: uidValidity, highestUID: highestUID, updatedAt: now()
        ))
    }
}
