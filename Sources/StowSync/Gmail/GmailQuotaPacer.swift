import Foundation

/// Spends Gmail API quota units at a steady rate, so a sync stays under
/// Google's per-user limit instead of running into it (brief step 6, D-598).
///
/// Google counts quota units per user per minute (6,000 since 1 May 2026) and
/// charges each call by kind (`GmailReadOnlyRequest.quotaUnits`). The pacer is a
/// token bucket: it refills at `unitsPerMinute` and holds at most `burst`
/// units, so in any 60 seconds a sync spends no more than
/// `unitsPerMinute + burst`. A request that finds too few units waits for them;
/// several waiting at once queue behind each other because each one reserves its
/// units before it sleeps.
actor GmailQuotaPacer {
    let unitsPerMinute: Double
    let burst: Double
    private var available: Double
    private var refilledAt: Date
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(unitsPerMinute: Int = ProviderProfile.gmailAPIUnitsPerMinute, burst: Int = ProviderProfile.gmailAPIUnitBurst,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.unitsPerMinute = Double(max(1, unitsPerMinute))
        self.burst = Double(max(1, burst))
        self.available = Double(max(1, burst))
        self.now = now
        self.refilledAt = now()
        self.sleep = sleep
    }

    /// Waits until `units` can be spent, then spends them.
    func spend(_ units: Int) async throws {
        let current = now()
        let perSecond = unitsPerMinute / 60
        available = min(burst, available + current.timeIntervalSince(refilledAt) * perSecond)
        refilledAt = current
        available -= Double(units)
        if available < 0 { try await sleep(-available / perSecond) }
    }
}
