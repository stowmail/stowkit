import Foundation
import os

/// Runs a piece of work on a thread of its own and waits for it at most a
/// fixed time (D-495, D-502). Used for PDFKit at import, for preparing a
/// message at import, and for each OCR item.
///
/// A thread cannot be stopped safely from outside, so work still running at
/// the limit is abandoned: the caller moves on and the result, if it ever
/// comes, is dropped. Abandoned work is counted until it finishes; while the
/// count is at `maximumAbandoned`, no more work is started, so stuck threads
/// cannot pile up. The count is per process unless a test passes its own.
public struct TimeLimit: Sendable {
    public enum Outcome<Value: Sendable>: Sendable {
        case finished(Value)
        /// Still running at the limit, and abandoned.
        case timedOut
        /// Not started: `maximumAbandoned` earlier calls are still stuck.
        case tooManyStuck
    }

    let limit: Duration
    let maximumAbandoned: Int
    let abandoned: OSAllocatedUnfairLock<Int>

    public init(limit: Duration, maximumAbandoned: Int, abandoned: OSAllocatedUnfairLock<Int>) {
        self.limit = limit
        self.maximumAbandoned = maximumAbandoned
        self.abandoned = abandoned
    }

    /// Abandoned calls still running.
    public var stuck: Int { abandoned.withLock { $0 } }

    private enum RunState<Value: Sendable>: Sendable { case running, finished(Value), abandoned }

    public func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) -> Outcome<Value> {
        let abandoned = abandoned
        guard abandoned.withLock({ $0 }) < maximumAbandoned else { return .tooManyStuck }
        let run = OSAllocatedUnfairLock<RunState<Value>>(initialState: .running)
        let done = DispatchSemaphore(value: 0)
        // A thread of its own, not a shared queue, so a stuck call holds no pool thread.
        Thread.detachNewThread {
            let result = work()
            let wasAbandoned = run.withLock { state in
                if case .abandoned = state { return true }
                state = .finished(result)
                return false
            }
            if wasAbandoned { abandoned.withLock { $0 -= 1 } }
            done.signal()
        }
        // DispatchTime does not advance while the Mac sleeps, so sleep never counts against the limit.
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        _ = done.wait(timeout: .now() + seconds)
        return run.withLock { state in
            if case .finished(let result) = state { return .finished(result) }
            state = .abandoned
            abandoned.withLock { $0 += 1 }
            return .timedOut
        }
    }
}
