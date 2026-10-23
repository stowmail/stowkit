import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowRules
import StowStore

/// `stowmail rules ...`: inspect the bulk-mail rules, run them over the archive, and set per-sender overrides.
struct Rules: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain, list and run the bulk-mail rules.",
        subcommands: [RulesList.self, RulesExplain.self, RulesReportCommand.self, RulesOverride.self]
    )
}

struct RulesOptions: ParsableArguments {
    @Option(name: .long, help: "Rule settings file. Defaults to ~/Library/Application Support/Stow/rules.json; the standard set is used if it does not exist.")
    var settings: String?

    var url: URL { settings.map { URL(fileURLWithPath: $0) } ?? EngineRules.defaultSettingsURL }

    /// Switches and weights from the file; sender overrides also from the archive, when there is one.
    func ruleSet() throws -> RuleSet {
        let archive = CLIArchive.location().exists ? try? CLIArchive.open(readOnly: true) : nil
        return try EngineRules.ruleSet(settings: url, archive: archive, account: nil)
    }
}

struct RulesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List every rule with its weight and whether it is on.")
    @OptionGroup var options: RulesOptions

    func run() async throws {
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

struct RulesExplain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "explain", abstract: "Show each signal, its result and the reason for one .eml file.")
    @OptionGroup var options: RulesOptions
    @Argument(help: "Path to an .eml file.") var file: String
    @Option(name: .long, help: "One of your own addresses. Repeat for several.") var owner: [String] = []

    func run() async throws {
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

/// Step 9: the rules over the real archive, with counts and sample reasons (no content).
struct RulesReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Run the rules over every archived message and show what they suggest.",
        discussion: "Stores each message's result, so `stowmail remove --suggestion` and `--rule` use the current rules. Shows counts and the most common reasons; reasons name sender domains at most, never addresses or subjects."
    )
    @OptionGroup var options: RulesOptions
    @Option(help: "One account only (ID, prefix, address or name).") var account: String?

    func run() async throws {
        CLI.bootstrapLogging()
        let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
        defer { lock.release() }
        let id = try account.map { try CLIArchive.accounts(archive).find($0).account.id }
        let report = try RulesRunner.run(archive, settings: options.url, account: id) { done, total in
            if done % 5000 == 0 || done == total { Swift.print("  \(done) of \(total)") }
        }
        print("\(report.messages) messages assessed.")
        for suggestion in Suggestion.allCases {
            let group = report.bySuggestion[suggestion] ?? RulesReport.Group()
            print("\(suggestion.label): \(group.messages) message(s), \(CLI.megabytes(group.bytes))")
            for sample in group.topReasons { print("    \(sample.count)x  \(sample.reason)") }
        }
        print("Signals that fired:")
        for signal in SignalID.allCases {
            print("  \(signal.rawValue): \(report.signalCounts[signal] ?? 0)")
        }
        if report.unreadable > 0 { print("\(report.unreadable) message(s) could not be read back; run `stowmail verify`.") }
    }
}

struct RulesOverride: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "override",
        abstract: "Always treat mail from an address or domain a certain way, or list and remove such overrides.",
        discussion: "Overrides are kept in the encrypted archive (D-041). Run `stowmail rules report` afterwards to apply them to archived mail."
    )

    @Argument(help: "An address or domain.") var match: String?
    @Argument(help: "keep, deprioritise or consider-deleting.") var suggestion: SuggestionArgument?
    @Option(help: "One account only (ID, prefix, address or name); default every account.") var account: String?
    @Flag(help: "Remove the override for this address or domain.") var remove = false

    func validate() throws {
        if remove, match == nil { throw ValidationError("Say which address or domain to remove.") }
        if !remove, match != nil, suggestion == nil { throw ValidationError("Say what to do: keep, deprioritise or consider-deleting.") }
    }

    func run() async throws {
        let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
        defer { lock.release() }
        let overrides = RuleOverrides(archive: archive)
        let id = try account.map { try CLIArchive.accounts(archive).find($0).account.id }
        if let match, remove {
            print(try overrides.remove(match, account: id) ? "Removed the override for \(match)." : "There was no override for \(match).")
        } else if let match, let suggestion {
            try overrides.set(match, suggestion.stored, account: id)
            print("Mail from \(match) is now treated as \(suggestion.rawValue).")
        }
        for o in try overrides.list(for: id) {
            print("  \(o.match) -> \(o.suggestion.rawValue)\(o.account == nil ? "" : " (one account)")")
        }
    }
}

/// Where explain gets parsed headers: the shared parser in StowCore (D-017).
enum HeaderSource {
    static func parse(_ raw: Data) throws -> MessageHeaders {
        try HeaderParser().parseHeaders(raw)
    }
}
