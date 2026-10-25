import Foundation
import GRDB
import StowCore
import StowRules
import StowStore

/// What `stowmail rules report` found (step 9): counts per suggestion and
/// per signal, with the most common reasons. Reasons name sender domains at
/// most (D-303); never addresses, subjects or content.
public struct RulesReport: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public var messages = 0
        public var bytes = 0
        /// The most common reasons, most common first.
        public var topReasons: [(reason: String, count: Int)] = []

        public init() {}

        public static func == (a: Group, b: Group) -> Bool {
            a.messages == b.messages && a.bytes == b.bytes && a.topReasons.map(\.reason) == b.topReasons.map(\.reason)
                && a.topReasons.map(\.count) == b.topReasons.map(\.count)
        }
    }

    public var messages = 0
    public var bySuggestion: [Suggestion: Group] = [:]
    public var signalCounts: [SignalID: Int] = [:]
    /// Protected messages (always keep, D-407), by why they are protected.
    public var protected: [Protection.Kind: Int] = [:]
    /// Messages whose headers could not be read back from the archive.
    public var unreadable = 0
}

/// Runs the current rules over every archived message, from its stored
/// headers, and stores the verdict with it (step 9, D-041). Run after
/// changing the rules so tidy-up and download order use the new ones.
public enum RulesRunner {
    /// `sender` (an address, or a domain matched exactly, as overrides and
    /// protected senders match) limits the run to that sender's mail: after the
    /// user protects or overrides one sender, only its messages need assessing again.
    public static func run(
        _ archive: Archive, settings: URL = EngineRules.defaultSettingsURL, account: AccountID? = nil, sender: String? = nil,
        samples: Int = 3, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> RulesReport {
        var report = RulesReport()
        var reasons: [Suggestion: [String: Int]] = [:]
        let accounts = try ArchiveAccounts(archive: archive).all().filter { account == nil || $0.account.id == account }
        var senderFilter = ""
        var senderArguments: [String] = []
        if let sender {
            let match = sender.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
            senderFilter = match.contains("@")
                ? "AND from_address_id IN (SELECT id FROM addresses WHERE address = ?)"
                : "AND from_address_id IN (SELECT id FROM addresses WHERE domain = ?)"
            senderArguments = [match]
        }
        let total = try archive.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE (? IS NULL OR account_id = ?) \(senderFilter)",
                             arguments: StatementArguments([account?.rawValue, account?.rawValue] + senderArguments)) ?? 0
        }
        var done = 0
        for record in accounts {
            let set = try EngineRules.ruleSet(settings: settings, archive: archive, account: record.account.id)
            let own: Set<String> = [record.account.email.lowercased()]
            let messages = try archive.database.read { db in
                try Row.fetchAll(db, sql: "SELECT id, size FROM messages WHERE account_id = ? \(senderFilter) ORDER BY id",
                                 arguments: StatementArguments([record.account.id.rawValue] + senderArguments))
                    .map { ($0["id"] as Int64, $0["size"] as Int) }
            }
            for start in stride(from: 0, to: messages.count, by: 500) {
                let batch = messages[start..<min(start + 500, messages.count)]
                var updates: [(Int64, StoredRuleResult)] = []
                for (id, size) in batch {
                    guard let header = try? autoreleasepool(invoking: { try archive.headerBlock(id) }) else {
                        report.unreadable += 1
                        continue
                    }
                    let assessment = set.assess(HeaderParser().parseHeaders(header), ownAddresses: own)
                    updates.append((id, EngineRules.stored(assessment)))
                    report.messages += 1
                    report.bySuggestion[assessment.suggestion, default: RulesReport.Group()].messages += 1
                    report.bySuggestion[assessment.suggestion, default: RulesReport.Group()].bytes += size
                    for outcome in assessment.outcomes where outcome.enabled && outcome.fired {
                        report.signalCounts[outcome.signal, default: 0] += 1
                    }
                    if let protection = assessment.protection { report.protected[protection.kind, default: 0] += 1 }
                    for reason in assessment.reasons { reasons[assessment.suggestion, default: [:]][reason, default: 0] += 1 }
                }
                try archive.database.write { db in
                    for (id, result) in updates {
                        try db.execute(sql: "UPDATE messages SET rule_suggestion = ?, rule_score = ?, rule_signals = ? WHERE id = ?",
                                       arguments: [result.suggestion.rawValue, result.score, result.signals.joined(separator: ","), id])
                    }
                }
                done += batch.count
                progress?(done, total)
            }
        }
        for (suggestion, counts) in reasons {
            report.bySuggestion[suggestion, default: RulesReport.Group()].topReasons = counts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(samples).map { ($0.key, $0.value) }
        }
        return report
    }
}
