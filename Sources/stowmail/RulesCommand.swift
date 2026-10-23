import ArgumentParser
import Foundation
import StowCore
import StowRules

/// `stowmail rules ...`: inspect the bulk-mail rules. Reads headers only; no network, no storage.
struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain and list the bulk-mail rules.",
        subcommands: [RulesList.self, RulesExplain.self]
    )
}

struct RulesOptions: ParsableArguments {
    @Option(name: .long, help: "Rule settings file. Defaults to ~/Library/Application Support/Stow/rules.json; the standard set is used if it does not exist.")
    var settings: String?

    func ruleSet() throws -> RuleSet {
        let url = settings.map { URL(fileURLWithPath: $0) } ?? Self.defaultURL
        return try RuleSet.load(from: url)
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stow/rules.json")
    }
}

struct RulesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List every rule with its weight and whether it is on.")
    @OptionGroup var options: RulesOptions

    func run() throws {
        let set = try options.ruleSet()
        print("Rules (a rule counts only when on and its signal fires):")
        for rule in set.rules {
            let signal = Signals.signal(rule.signal)
            print("  [\(rule.enabled ? "on " : "off")] \(rule.signal.rawValue)  weight \(rule.weight)  \(signal.strength.rawValue)  \(signal.title)")
        }
        print("Deprioritise at score \(set.deprioritiseAt).")
        print("Consider deleting from source at score \(set.considerDeletingAt) with at least \(set.minimumStrongSignals) strong signals.")
        print("Recipient count limit: \(set.recipientThreshold).")
        print("Sender overrides: \(set.senderOverrides.count)")
        for o in set.senderOverrides { print("  \(o.match) -> \(o.suggestion.label)") }
    }
}

struct RulesExplain: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "explain", abstract: "Show each signal, its result and the reason for one .eml file.")
    @OptionGroup var options: RulesOptions
    @Argument(help: "Path to an .eml file.") var file: String
    @Option(name: .long, help: "One of your own addresses. Repeat for several.") var owner: [String] = []

    func run() throws {
        let raw = try Data(contentsOf: URL(fileURLWithPath: file))
        let headers = try HeaderSource.parse(raw)
        if owner.isEmpty {
            print("Note: no --owner given, so the \"you are not a direct recipient\" signal cannot be checked.")
        }
        let a = try options.ruleSet().assess(headers, ownAddresses: Set(owner))
        for o in a.outcomes {
            let state = !o.enabled ? "off  " : (o.fired ? "FIRED" : "no   ")
            print("[\(state)] \(o.signal.rawValue) (\(o.strength.rawValue), weight \(o.weight)): \(o.reason)")
        }
        print("Score: \(a.score)")
        print("Suggestion: \(a.suggestion.label)")
        print("Reasons:")
        for r in a.reasons { print("  - \(r)") }
    }
}

/// Where explain gets parsed headers. Header parsing belongs to StowCore (D-017, Track B);
/// this is the one place to wire it in once that merges.
enum HeaderSource {
    static func parse(_ raw: Data) throws -> MessageHeaders {
        throw ValidationError("The header parser from Track B is not merged yet, so .eml files cannot be read.")
    }
}
