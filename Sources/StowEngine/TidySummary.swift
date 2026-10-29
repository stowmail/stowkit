import Foundation
import GRDB
import StowCore
import StowRules
import StowStore

/// Everything Tidy up shows, in one call (D-058, D-098, R13): per suggestion,
/// groups by sender with counts, sizes, newest date and reasons; a group per
/// source state for "You changed these in Gmail" (D-022); and protected totals.
///
/// Built on the verdicts stored with each message (D-041) and the same
/// selections as `ArchiveRemoval.plan`, never by parsing messages again, so the
/// numbers match `stowmail remove --dry-run` for the same selection. Reasons
/// are the signals' own wording and name no address or subject (D-303).
public struct TidySummary: Sendable, Equatable {
    /// One sender's mail within a suggestion.
    public struct SenderGroup: Sendable, Equatable {
        /// The From address, normalised; empty for mail without one.
        public var address: String
        public var domain: String
        /// The display name on the latest email stored from this sender, if it had one.
        public var name: String?
        public var messages: Int
        public var bytes: Int
        public var newest: Date
        /// Why the rules suggested this, most common first: signal titles, and a note when
        /// the user's own choice for the sender decided it. Never an address or subject.
        public var reasons: [String]
        /// This sender's protected mail: a rule or suggestion never removes it (D-407).
        public var protectedLeftOut: Int
    }

    /// Everything the rules gave one suggestion.
    public struct SuggestionGroup: Sendable, Equatable {
        public var suggestion: StoredRuleResult.Suggestion
        /// As `ArchiveRemoval.plan(.suggestion(_:))` counts them.
        public var messages: Int
        public var bytes: Int
        public var senderDomains: Int
        /// Most messages first, then most bytes.
        public var senders: [SenderGroup]
    }

    /// Mail in one state at the provider (D-039), for "You changed these in Gmail".
    public struct SourceGroup: Sendable, Equatable {
        public var state: SourceState
        /// As `ArchiveRemoval.plan(.sourceState(_:))` counts them; protected mail included.
        public var messages: Int
        public var bytes: Int
        public var newest: Date?
        /// Protected messages among them: included because the user chooses the group.
        public var protectedIncluded: Int
        /// Trashed or gone mail older than its account's retention cutoff (D-034): expected,
        /// since the user's retention deleted it. Never counts spam. 0 with no retention set.
        public var olderThanRetention: Int
        /// The rest, which Tidy up offers to remove: equal to `plan(.recentSourceState(_:))`.
        public var recent: Int { messages - olderThanRetention }
    }

    public var suggestions: [SuggestionGroup]
    public var sourceStates: [SourceGroup]
    /// Protected mail by why it is protected (D-407).
    public var protectedByKind: [Protection.Kind: Int]
    public var protectedTotal: Int
    /// Messages in the summary's scope.
    public var messages: Int
    /// Set when the protection lists could not be loaded: then nothing is offered
    /// for removal (`suggestions` is empty) and this says why (A-19, D-517).
    public var rulesProblem: String?

    /// The two suggestions Tidy up offers, in the order it shows them.
    public static let offered: [StoredRuleResult.Suggestion] = [.considerDeleting, .deprioritise]

    /// The summary for one account, or every account. `settings` gives the protected
    /// senders' rule set, used only to say why each protected message is protected.
    public static func compute(_ archive: Archive, account: AccountID? = nil, settings: URL = EngineRules.defaultSettingsURL,
                               now: Date = Date(), data: RulesData = .bundled) throws -> TidySummary {
        let protectionRules = try EngineRules.ruleSet(settings: settings, archive: archive, account: account)
        let overrides = try RuleOverrides(archive: archive).list(for: account)
        return try archive.database.read { db in
            let scope = account.map { _ in "m.account_id = ?" } ?? "1"
            let scopeArguments: [any DatabaseValueConvertible] = account.map { [$0.rawValue] } ?? []
            let isProtected = Self.isProtectedSQL
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages m WHERE \(scope)",
                                         arguments: StatementArguments(scopeArguments)) ?? 0

            // Each sender's protected mail, which a rule or suggestion leaves out.
            var protectedBySender: [Int64?: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT m.from_address_id AS sender, count(*) AS n FROM messages m WHERE \(scope) AND \(isProtected)
                GROUP BY m.from_address_id
                """, arguments: StatementArguments(scopeArguments)) {
                protectedBySender[row["sender"]] = row["n"]
            }

            let signals = SignalID.allCases
            let signalSums = signals.map { "sum(instr(',' || coalesce(m.rule_signals, '') || ',', ',\($0.rawValue),') > 0)" }
                .joined(separator: ", ")
            var groups: [SuggestionGroup] = []
            for suggestion in offered where data.loadProblem == nil {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.from_address_id AS sender, a.address, a.domain, count(*) AS n, sum(m.size) AS bytes,
                        max(m.internal_date) AS newest, max(m.id) AS newest_id, \(signalSums)
                    FROM messages m LEFT JOIN addresses a ON a.id = m.from_address_id
                    WHERE \(scope) AND m.rule_suggestion = ? AND NOT \(isProtected)
                    GROUP BY m.from_address_id
                    """, arguments: StatementArguments(scopeArguments + [suggestion.rawValue]))
                var senders: [SenderGroup] = []
                for row in rows {
                    let address: String = row["address"] ?? ""
                    let domain: String = row["domain"] ?? ""
                    let count: Int = row["n"]
                    // Signal titles by how many of the sender's emails they fired on (D-303 wording).
                    var fired: [(SignalID, Int)] = []
                    for (index, signal) in signals.enumerated() {
                        let hits: Int = row[7 + index] ?? 0
                        if hits > 0 { fired.append((signal, hits)) }
                    }
                    var reasons = fired.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
                        .compactMap { Self.title[$0.0] }
                    if let choice = overrides.first(where: { Self.matches($0.match, address: address, domain: domain) }),
                       choice.suggestion == suggestion {
                        reasons.insert(choice.match.contains("@") ? "Your choice for this sender."
                                       : "Your choice for \(choice.match).", at: 0)
                    }
                    senders.append(SenderGroup(
                        address: address, domain: domain, name: nil, messages: count, bytes: row["bytes"],
                        newest: Date(timeIntervalSince1970: TimeInterval(row["newest"] as Int64)), reasons: reasons,
                        protectedLeftOut: protectedBySender[row["sender"]] ?? 0))
                }
                try Self.fillNames(db, &senders, rows: rows)
                senders.sort { $0.messages != $1.messages ? $0.messages > $1.messages
                    : $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.address < $1.address }
                groups.append(SuggestionGroup(
                    suggestion: suggestion, messages: senders.reduce(0) { $0 + $1.messages },
                    bytes: senders.reduce(0) { $0 + $1.bytes },
                    senderDomains: Set(senders.map(\.domain).filter { !$0.isEmpty }).count, senders: senders))
            }

            // "You changed these in Gmail": by source state, with what retention explains (D-022, D-039).
            let cutoffs = try ArchiveRemoval.retentionCutoffs(db, now: now)
            var states: [SourceGroup] = []
            for state in [SourceState.spam, .trashed, .gone] {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.account_id, count(*) AS n, sum(m.size) AS bytes, max(m.internal_date) AS newest,
                        sum(\(isProtected)) AS protected
                    FROM messages m WHERE \(scope) AND m.source_state = ? GROUP BY m.account_id
                    """, arguments: StatementArguments(scopeArguments + [state.rawValue]))
                var group = SourceGroup(state: state, messages: 0, bytes: 0, newest: nil, protectedIncluded: 0, olderThanRetention: 0)
                for row in rows {
                    group.messages += row["n"] as Int
                    group.bytes += row["bytes"] as Int
                    group.protectedIncluded += row["protected"] as Int
                    let newest = Date(timeIntervalSince1970: TimeInterval(row["newest"] as Int64))
                    group.newest = max(group.newest ?? newest, newest)
                    if state != .spam, let cutoff = cutoffs[row["account_id"] as String] {
                        group.olderThanRetention += try Int.fetchOne(db, sql: """
                            SELECT count(*) FROM messages WHERE account_id = ? AND source_state = ? AND internal_date < ?
                            """, arguments: [row["account_id"] as String, state.rawValue, cutoff]) ?? 0
                    }
                }
                states.append(group)
            }

            // Why protected mail is protected: from the stored From address and subject, not the message.
            var byKind: [Protection.Kind: Int] = [:]
            var protectedTotal = 0
            for row in try Row.fetchAll(db, sql: """
                SELECT ma.display_name, a.address, m.subject FROM messages m
                LEFT JOIN message_addresses ma ON ma.message_id = m.id AND ma.role = 'from' AND ma.position = 0
                LEFT JOIN addresses a ON a.id = ma.address_id
                WHERE \(scope) AND \(isProtected)
                """, arguments: StatementArguments(scopeArguments)) {
                protectedTotal += 1
                let from = (row["address"] as String?).map { [EmailAddress(name: row["display_name"], address: $0)] } ?? []
                let kind = protectionRules.protection(MessageHeaders(from: from, subject: row["subject"]), data: data)?.kind ?? .subjectKeyword
                byKind[kind, default: 0] += 1
            }
            return TidySummary(suggestions: groups, sourceStates: states, protectedByKind: byKind,
                               protectedTotal: protectedTotal, messages: total, rulesProblem: data.loadProblem?.description)
        }
    }

    /// The stored protected marker (D-407), as `ArchiveRemoval.plan` tests it.
    static let isProtectedSQL = "((',' || coalesce(m.rule_signals, '') || ',') LIKE '%,\(StoredRuleResult.protectedMarker),%')"

    /// Each signal's title, as `stowmail rules list` and Settings show it.
    static let title: [SignalID: String] = Dictionary(uniqueKeysWithValues: SignalID.allCases.map { ($0, Signals.signal($0).title) })

    /// An override's match against a sender: a full address, or an exact domain (as `SenderOverride` matches).
    static func matches(_ match: String, address: String, domain: String) -> Bool {
        match.contains("@") ? match == address : match.trimmingCharacters(in: CharacterSet(charactersIn: "@")) == domain
    }

    /// The display name on the latest email stored from each sender in the group.
    static func fillNames(_ db: Database, _ senders: inout [SenderGroup], rows: [Row]) throws {
        let newest = rows.map { $0["newest_id"] as Int64 }
        var names: [Int64: String] = [:]
        for start in stride(from: 0, to: newest.count, by: 500) {
            let chunk = Array(newest[start..<min(start + 500, newest.count)])
            for row in try Row.fetchAll(db, sql: """
                SELECT message_id, display_name FROM message_addresses
                WHERE role = 'from' AND position = 0 AND display_name IS NOT NULL
                    AND message_id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ", ")))
                """, arguments: StatementArguments(chunk)) {
                names[row["message_id"]] = row["display_name"]
            }
        }
        for index in senders.indices { senders[index].name = names[newest[index]] }
    }
}
