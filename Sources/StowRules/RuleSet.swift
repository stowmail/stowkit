import Foundation
import StowCore

/// What Stow suggests doing with a message. Only ever a suggestion: nothing is deleted or hidden by it.
public enum Suggestion: String, Codable, Comparable, Sendable, CaseIterable {
    case keep
    case deprioritise
    case considerDeletingFromSource

    private var order: Int {
        switch self {
        case .keep: 0
        case .deprioritise: 1
        case .considerDeletingFromSource: 2
        }
    }
    public static func < (a: Suggestion, b: Suggestion) -> Bool { a.order < b.order }

    public var label: String {
        switch self {
        case .keep: "keep"
        case .deprioritise: "deprioritise"
        case .considerDeletingFromSource: "consider deleting from source"
        }
    }
}

/// One signal with a weight, switched on or off.
public struct Rule: Codable, Hashable, Sendable {
    public var signal: SignalID
    public var enabled: Bool
    public var weight: Int

    public init(signal: SignalID, enabled: Bool = true, weight: Int) {
        self.signal = signal
        self.enabled = enabled
        self.weight = weight
    }
}

/// "Always treat mail from this sender like this." `match` is a full address
/// (`news@shop.example`) or a bare domain (`shop.example`, exact domain only).
public struct SenderOverride: Codable, Hashable, Sendable {
    public var match: String
    public var suggestion: Suggestion

    public init(match: String, suggestion: Suggestion) {
        self.match = match.trimmingCharacters(in: .whitespaces).lowercased()
        self.suggestion = suggestion
    }

    func matches(_ sender: EmailAddress) -> Bool {
        match.contains("@") ? sender.normalised == match : sender.domain == match.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }
}

/// One rule's contribution to an assessment, shown by `rules explain`.
public struct RuleOutcome: Hashable, Sendable {
    public var signal: SignalID
    public var title: String
    public var strength: SignalStrength
    public var enabled: Bool
    public var fired: Bool
    public var weight: Int
    public var reason: String
}

/// The answer for one message: a score, a suggestion and the reasons for both.
public struct Assessment: Hashable, Sendable {
    public var score: Int
    public var suggestion: Suggestion
    public var outcomes: [RuleOutcome]
    /// Plain-English reasons, one per signal that counted, plus any override or threshold note.
    public var reasons: [String]
    /// Set when a per-sender override decided the suggestion.
    public var overriddenBy: String?
}

/// The full, user-editable rule configuration. Saved as versioned JSON.
public struct RuleSet: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var rules: [Rule]
    /// Score at which mail is deprioritised.
    public var deprioritiseAt: Int
    /// Score at which "consider deleting" becomes possible (it also needs `minimumStrongSignals`).
    public var considerDeletingAt: Int
    public var minimumStrongSignals: Int
    public var recipientThreshold: Int
    public var senderOverrides: [SenderOverride]

    public init(
        version: Int = RuleSet.currentVersion,
        rules: [Rule],
        deprioritiseAt: Int = 3,
        considerDeletingAt: Int = 6,
        minimumStrongSignals: Int = 2,
        recipientThreshold: Int = 20,
        senderOverrides: [SenderOverride] = []
    ) {
        self.version = version
        self.rules = rules
        self.deprioritiseAt = deprioritiseAt
        self.considerDeletingAt = considerDeletingAt
        self.minimumStrongSignals = minimumStrongSignals
        self.recipientThreshold = recipientThreshold
        self.senderOverrides = senderOverrides
    }

    /// The conservative default set (D-301).
    public static let standard = RuleSet(rules: [
        Rule(signal: .listUnsubscribe, weight: 3),
        Rule(signal: .precedenceBulk, weight: 3),
        Rule(signal: .senderListProvider, weight: 2),
        Rule(signal: .senderNoReply, weight: 2),
        Rule(signal: .userNotInTo, weight: 1),
        Rule(signal: .recipientCount, weight: 1),
        Rule(signal: .replyToDiffers, weight: 1),
    ])

    public mutating func setEnabled(_ signal: SignalID, _ enabled: Bool) {
        if let i = rules.firstIndex(where: { $0.signal == signal }) {
            rules[i].enabled = enabled
        } else {
            rules.append(Rule(signal: signal, enabled: enabled, weight: 1))
        }
    }

    /// Assess one message from its headers alone.
    public func assess(
        _ headers: MessageHeaders,
        ownAddresses: Set<String> = [],
        data: RulesData = .bundled
    ) -> Assessment {
        let context = SignalContext(ownAddresses: ownAddresses, recipientThreshold: recipientThreshold, data: data)
        var outcomes: [RuleOutcome] = []
        var score = 0
        var strong = 0
        var reasons: [String] = []

        for rule in rules {
            let signal = Signals.signal(rule.signal)
            let r = signal.evaluate(headers, context: context)
            outcomes.append(RuleOutcome(
                signal: rule.signal, title: signal.title, strength: signal.strength,
                enabled: rule.enabled, fired: r.fired, weight: rule.weight, reason: r.reason))
            if rule.enabled && r.fired {
                score += rule.weight
                if signal.strength == .strong { strong += 1 }
                reasons.append(r.reason)
            }
        }

        var suggestion = Suggestion.keep
        if score >= considerDeletingAt && strong >= minimumStrongSignals {
            suggestion = .considerDeletingFromSource
        } else if score >= deprioritiseAt {
            suggestion = .deprioritise
            if score >= considerDeletingAt {
                reasons.append("Score is high enough to consider deleting, but fewer than \(minimumStrongSignals) strong signals fired, so it is only deprioritised.")
            }
        }

        var overriddenBy: String?
        if let sender = headers.from.first, let o = senderOverrides.first(where: { $0.matches(sender) }) {
            suggestion = o.suggestion
            overriddenBy = "Your override for this sender: \(o.suggestion.label)."
            reasons.append(overriddenBy!)
        }
        if reasons.isEmpty { reasons.append("No bulk-mail signals found.") }

        return Assessment(score: score, suggestion: suggestion, outcomes: outcomes, reasons: reasons, overriddenBy: overriddenBy)
    }
}

public enum RuleSetError: Error, CustomStringConvertible {
    case unsupportedVersion(Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): "Rule settings file is version \(v); this build understands version \(RuleSet.currentVersion)."
        case .unreadable(let why): "Rule settings file could not be read: \(why)"
        }
    }
}

extension RuleSet {
    /// Reads settings. A missing file gives the standard set; a damaged or newer file is an error,
    /// never silently replaced.
    public static func load(from url: URL) throws -> RuleSet {
        guard FileManager.default.fileExists(atPath: url.path) else { return .standard }
        let set: RuleSet
        do {
            set = try JSONDecoder().decode(RuleSet.self, from: Data(contentsOf: url))
        } catch {
            throw RuleSetError.unreadable("not valid rule settings")
        }
        guard set.version == currentVersion else { throw RuleSetError.unsupportedVersion(set.version) }
        return set
    }

    /// Writes settings atomically with owner-only permissions.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
