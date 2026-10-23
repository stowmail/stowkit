import Foundation
import StowCore
import StowRules
import StowStore

/// Joins the rules engine to sync and storage: download order (D-028) and
/// the verdict stored with each message (D-041).
public enum EngineRules {
    /// Where rule switches and weights are kept for the CLI (D-304).
    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Stow/rules.json")
    }

    /// The rule settings for `account`: switches and weights from the settings
    /// file, sender overrides from the archive (its own and every account's)
    /// ahead of any still in the file.
    public static func ruleSet(settings url: URL = defaultSettingsURL, archive: Archive?, account: AccountID?) throws -> RuleSet {
        var set = try RuleSet.load(from: url)
        if let archive {
            let stored = try RuleOverrides(archive: archive).list(for: account).map {
                SenderOverride(match: $0.match, suggestion: suggestion($0.suggestion))
            }
            set.senderOverrides = stored + set.senderOverrides
        }
        return set
    }

    /// Download order from the listed header fields: mail the rules keep comes
    /// first (0), deprioritised mail next (1), and mail they would suggest
    /// deleting last (2). Everything is still downloaded (D-020).
    public static func prioritiser(_ set: RuleSet, ownAddress: String) -> DownloadPrioritiser {
        let own: Set<String> = [ownAddress.lowercased()]
        return { fields in
            priority(set.assess(HeaderParser().parseHeaders(fields), ownAddresses: own).suggestion)
        }
    }

    /// The verdict stored with each imported message.
    public static func classifier(_ set: RuleSet) -> RuleClassifier {
        { headers, own in stored(set.assess(headers, ownAddresses: own)) }
    }

    public static func priority(_ suggestion: Suggestion) -> Int {
        switch suggestion {
        case .keep: 0
        case .deprioritise: 1
        case .considerDeletingFromSource: 2
        }
    }

    public static func stored(_ assessment: Assessment) -> StoredRuleResult {
        let suggestion: StoredRuleResult.Suggestion = switch assessment.suggestion {
        case .keep: .keep
        case .deprioritise: .deprioritise
        case .considerDeletingFromSource: .considerDeleting
        }
        return StoredRuleResult(suggestion: suggestion, score: assessment.score,
                                signals: assessment.outcomes.filter { $0.enabled && $0.fired }.map(\.signal.rawValue))
    }

    static func suggestion(_ stored: StoredRuleResult.Suggestion) -> Suggestion {
        switch stored {
        case .keep: .keep
        case .deprioritise: .deprioritise
        case .considerDeleting: .considerDeletingFromSource
        }
    }
}
