import Foundation

/// How long to wait before reconnecting after a dropped connection, a BYE or
/// a throttling reply (D-107). Doubles each time: 2 s, 4 s, 8 s, ... up to
/// five minutes, and gives up after `maxAttempts` failures in a row without progress.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval

    public init(maxAttempts: Int = 5, initialDelay: TimeInterval = 2, maximumDelay: TimeInterval = 300) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }

    /// The pause before retry number `attempt` (1-based).
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        return min(maximumDelay, initialDelay * pow(2, exponent))
    }

    public static let `default` = RetryPolicy()
}
