import Foundation
import GRDB
import StowCore

/// The user's per-sender decisions about the rules (`rule_overrides`, D-041):
/// "always treat mail from this address or domain as keep / deprioritise /
/// consider deleting". Rule on/off switches and weights stay in `rules.json`
/// (D-304); these live in the archive because they name senders.
public struct RuleOverrides: Sendable {
    public struct Override: Sendable, Equatable {
        /// A normalised address (`news@shop.example`) or a bare domain (`shop.example`).
        public var match: String
        public var suggestion: StoredRuleResult.Suggestion
        /// Nil for every account.
        public var account: AccountID?
    }

    public let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    /// Overrides that apply to `account`: its own and the ones for every account.
    public func list(for account: AccountID? = nil) throws -> [Override] {
        try archive.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT account_id, match, suggestion FROM rule_overrides
                WHERE account_id IS NULL OR account_id = ? ORDER BY account_id IS NULL, match
                """, arguments: [account?.rawValue])
            return rows.compactMap { row in
                guard let suggestion = StoredRuleResult.Suggestion(rawValue: row["suggestion"]) else { return nil }
                return Override(match: row["match"], suggestion: suggestion,
                                account: (row["account_id"] as String?).map(AccountID.init(rawValue:)))
            }
        }
    }

    /// Adds or replaces an override.
    public func set(_ match: String, _ suggestion: StoredRuleResult.Suggestion, account: AccountID? = nil) throws {
        let normalised = Self.normalise(match)
        try archive.database.write { db in
            try db.execute(sql: "DELETE FROM rule_overrides WHERE coalesce(account_id, '') = ? AND match = ?",
                           arguments: [account?.rawValue ?? "", normalised])
            try db.execute(sql: "INSERT INTO rule_overrides (account_id, match, suggestion, created_at) VALUES (?, ?, ?, ?)",
                           arguments: [account?.rawValue, normalised, suggestion.rawValue, Int(Date().timeIntervalSince1970)])
        }
    }

    /// Removes an override. Returns whether there was one.
    @discardableResult
    public func remove(_ match: String, account: AccountID? = nil) throws -> Bool {
        try archive.database.write { db in
            try db.execute(sql: "DELETE FROM rule_overrides WHERE coalesce(account_id, '') = ? AND match = ?",
                           arguments: [account?.rawValue ?? "", Self.normalise(match)])
            return db.changesCount > 0
        }
    }

    static func normalise(_ match: String) -> String {
        match.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
    }
}
