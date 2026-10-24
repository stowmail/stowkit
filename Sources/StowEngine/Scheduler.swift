import Foundation
import Logging
import StowCore
import StowStore
import StowSync

/// How the scheduler paces itself (D-036).
public struct SchedulerSettings: Sendable {
    /// Longest turn one account gets before the next account's turn.
    public var turn: TimeInterval
    /// Pause between rounds when nothing was downloaded: how quickly new mail is noticed.
    public var idleInterval: TimeInterval
    /// How often each account's archived mail is compared in full with the server.
    public var fullCheckInterval: TimeInterval
    /// Longest wait before retrying an account that keeps failing.
    public var maximumBackoff: TimeInterval
    /// Shortest wait once the daily byte budget is used up, however soon it frees up (D-036).
    public var budgetMinimumWait: TimeInterval

    public init(turn: TimeInterval = 120, idleInterval: TimeInterval = 300, fullCheckInterval: TimeInterval = 6 * 3600,
                maximumBackoff: TimeInterval = 3600, budgetMinimumWait: TimeInterval = 300) {
        self.turn = turn
        self.idleInterval = idleInterval
        self.fullCheckInterval = fullCheckInterval
        self.maximumBackoff = maximumBackoff
        self.budgetMinimumWait = budgetMinimumWait
    }
}

/// What one account's turn came to.
public enum TurnOutcome: Sendable, Equatable {
    case synced(SyncReport)
    case failed(String)
    /// Waiting before trying again, until the given time.
    case waiting(until: Date)
}

/// What a whole round came to.
public enum RoundResult: Sendable, Equatable {
    /// Something was downloaded, or an account still has work: go again soon.
    case worked
    /// Every account is up to date.
    case idle
    /// Not syncing for now, for this reason (battery, Low Power Mode, no confirmed recovery key).
    case paused(String)
    /// The archive's folder is not available, for example a disconnected disk (D-023).
    case offline(String)
    /// Another Stow process is writing to the archive.
    case busy
}

/// Spreads sync across accounts, invisibly and gently (step 5, D-036).
///
/// Each round gives every connected account one turn, in rotating order: at
/// most `turn` seconds of downloading on one connection, then the next
/// account. An account that fails waits longer each time (5, 10, 20 minutes,
/// up to an hour); one whose provider limit or Stow's daily budget is used up
/// waits hours. The archive is opened afresh each round, so a disconnected
/// disk pauses sync and a reconnected one resumes it, and the writer lock is
/// held for the round, so a CLI command waits for at most one round.
public actor Scheduler {
    let settings: SchedulerSettings
    let openArchive: @Sendable () throws -> Archive
    let makeSync: @Sendable (Archive) throws -> EngineSync
    let power: @Sendable () -> PowerState
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    private let logger = Logger(label: "ee.getstow.engine.scheduler")

    private var notBefore: [AccountID: Date] = [:]
    private var failures: [AccountID: Int] = [:]
    private var lastFullCheck: [AccountID: Date] = [:]
    private var nextStart = 0
    private var lastLogged: RoundResult?
    private var swept = false

    public init(
        settings: SchedulerSettings = SchedulerSettings(),
        openArchive: @escaping @Sendable () throws -> Archive,
        makeSync: @escaping @Sendable (Archive) throws -> EngineSync,
        power: @escaping @Sendable () -> PowerState = { PowerState.current() },
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.settings = settings
        self.openArchive = openArchive
        self.makeSync = makeSync
        self.power = power
        self.now = now
        self.sleep = sleep
    }

    /// Runs rounds until cancelled, pausing between them as the last round's result says.
    public func run() async {
        while !Task.isCancelled {
            let (result, _) = await round()
            if result != lastLogged {
                switch result {
                case .paused(let reason): logger.notice("Sync paused", metadata: ["reason": "\(reason)"])
                case .offline: logger.notice("Archive offline; sync paused until it is back")
                case .busy: logger.info("Archive busy; waiting")
                case .worked, .idle: if lastLogged != nil, lastLogged != .worked, lastLogged != .idle { logger.notice("Sync resumed") }
                }
                lastLogged = result
            }
            let pause: TimeInterval = switch result {
            case .worked: 1
            case .idle: settings.idleInterval
            case .paused, .offline: 60
            case .busy: 30
            }
            do {
                try await sleep(pause)
            } catch {
                return
            }
        }
    }

    /// One turn for every connected account that is not waiting.
    public func round() async -> (RoundResult, [AccountID: TurnOutcome]) {
        if let reason = power().pauseReason { return (.paused(reason), [:]) }
        let archive: Archive
        do {
            archive = try openArchive()
        } catch let error as ArchiveLocationError {
            return (.offline(error.description), [:])
        } catch {
            return (.offline(Redact.scrub(String(describing: error))), [:])
        }
        defer { try? archive.database.close() }
        guard ArchiveSetup.isConfirmed(archive) else { return (.paused(ArchiveSetupError.recoveryNotConfirmed.description), [:]) }
        guard let lock = try? ArchiveLock.acquire(archive.location) else { return (.busy, [:]) }
        defer { lock.release() }
        if !swept {
            // Files written by a batch that was killed before it was recorded. Only
            // safe while holding the lock, so nothing is mid-write.
            swept = true
            if let count = try? ArchiveRemoval(archive: archive).sweepUnusedFiles(), count > 0 {
                logger.notice("Deleted unused files left by an interrupted sync", metadata: ["count": "\(count)"])
            }
        }

        let accounts = ArchiveAccounts(archive: archive)
        let records = ((try? accounts.connected()) ?? []).filter { !$0.needsSignIn }
        guard !records.isEmpty else { return (.idle, [:]) }
        let start = nextStart % records.count
        nextStart += 1
        let sync: EngineSync
        do {
            sync = try makeSync(archive)
        } catch {
            return (.paused(Self.plainWords(error)), [:])
        }
        var outcomes: [AccountID: TurnOutcome] = [:]
        var worked = false

        for record in records[start...] + records[..<start] {
            let id = record.account.id
            if let waitUntil = notBefore[id], now() < waitUntil {
                outcomes[id] = .waiting(until: waitUntil)
                continue
            }
            if power().pauseReason != nil { break }
            let full = lastFullCheck[id].map { now().timeIntervalSince($0) >= settings.fullCheckInterval } ?? true
            let options = SyncOptions(deadline: now().addingTimeInterval(settings.turn), checkChanges: full ? .full : .quick)
            do {
                let report = try await sync.syncer(for: record.account).run(options)
                try accounts.recordSync(id, at: now(), error: nil)
                do {
                    _ = try Coverage.compute(archive, account: id, now: now())
                } catch {
                    logger.warning("Coverage date not updated", metadata: ["account": "\(id)", "error": "\(Self.plainWords(error))"])
                }
                failures[id] = 0
                notBefore[id] = nil
                if full, report.outcome == .complete, report.remaining.queued == 0 { lastFullCheck[id] = now() }
                if case .budgetExhausted(let used, let limit, let needed) = report.outcome {
                    notBefore[id] = await budgetWait(archive, account: id, mustFree: used + needed - limit)
                }
                if report.messagesWritten > 0 || report.outcome == .yielded { worked = true }
                outcomes[id] = .synced(report)
            } catch {
                let text = Self.plainWords(error)
                try? accounts.recordSync(id, at: now(), error: text)
                let count = (failures[id] ?? 0) + 1
                failures[id] = count
                let wait: TimeInterval = switch error {
                case SyncError.mailboxUnavailable: 24 * 3600
                case SyncError.quotaExceeded: 6 * 3600
                case SyncError.budgetExhausted: 3600
                default: min(settings.maximumBackoff, 300 * pow(2, Double(count - 1)))
                }
                notBefore[id] = now().addingTimeInterval(wait)
                outcomes[id] = .failed(text)
                logger.warning("Account sync failed; will try again later", metadata: [
                    "account": "\(id)", "error": "\(text)", "retryIn": "\(Int(wait))",
                ])
            }
        }
        try? archive.setMeta("daemon_heartbeat", String(Int(now().timeIntervalSince1970)))
        return (worked ? .worked : .idle, outcomes)
    }

    /// When to try again after the byte budget ran out: as soon as enough of the
    /// last 24 hours' downloads have aged out for the batch that did not fit, but
    /// not sooner than `budgetMinimumWait`. An hour if that can never happen.
    func budgetWait(_ archive: Archive, account: AccountID, mustFree bytes: Int64) async -> Date {
        let earliest = now().addingTimeInterval(settings.budgetMinimumWait)
        guard let freed = try? await ArchiveSyncStore(archive: archive).budgetFreesUp(account, bytes: max(1, bytes), now: now()) else {
            return now().addingTimeInterval(3600)
        }
        return max(earliest, freed)
    }

    /// An error in plain words, scrubbed (D-014). Sync errors already read as sentences.
    static func plainWords(_ error: Error) -> String {
        Redact.scrub(String(describing: error))
    }
}
