import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowRules
import StowStore

enum SuggestionArgument: String, ExpressibleByArgument, CaseIterable {
    case keep
    case deprioritise
    case considerDeleting = "consider-deleting"

    var stored: StoredRuleResult.Suggestion {
        switch self {
        case .keep: .keep
        case .deprioritise: .deprioritise
        case .considerDeleting: .considerDeleting
        }
    }
}

enum SourceStateArgument: String, ExpressibleByArgument, CaseIterable {
    case spam, trashed, gone

    var state: SourceState {
        switch self {
        case .spam: .spam
        case .trashed: .trashed
        case .gone: .gone
        }
    }
}

/// Removing mail from the archive (D-020, D-033). Never touches the mailbox.
struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove mail from the archive by rule, suggestion, sender or what happened to it in the mailbox.",
        discussion: """
            Shows how many messages and how much space first. Removing mail from Stow does not touch your mailbox. \
            Removed messages are remembered so sync never downloads them again; `stowmail restore` brings them back \
            while the provider still has them. Run `stowmail rules report` first so the rules are up to date.
            """
    )

    @Option(help: "A rules signal that fired, for example listUnsubscribe (see `stowmail rules list`).") var rule: String?
    @Option(help: "What the rules suggested: keep, deprioritise or consider-deleting.") var suggestion: SuggestionArgument?
    @Option(help: "An address, or a domain (which includes its subdomains).") var sender: String?
    @Option(help: "What happened in the mailbox: spam, trashed or gone.") var source: SourceStateArgument?
    @Option(help: "One account only (ID, prefix, address or name).") var account: String?
    @Flag(help: "Show what would be removed, and remove nothing.") var dryRun = false
    @Flag(help: "Do not ask for confirmation.") var yes = false

    func validate() throws {
        let given = [rule != nil, suggestion != nil, sender != nil, source != nil].filter { $0 }.count
        guard given == 1 else { throw ValidationError("Give exactly one of --rule, --suggestion, --sender or --source.") }
        if let rule, SignalID(rawValue: rule) == nil {
            throw ValidationError("Unknown rule \(rule). Rules: \(SignalID.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
    }

    var selector: RemovalSelector {
        if let rule { return .signal(rule) }
        if let suggestion { return .suggestion(suggestion.stored) }
        if let sender { return .sender(sender) }
        return .sourceState(source!.state)
    }

    func run() async throws {
        CLI.bootstrapLogging()
        let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
        defer { lock.release() }
        let id = try account.map { try CLIArchive.accounts(archive).find($0).account.id }
        let removal = ArchiveRemoval(archive: archive)
        _ = try removal.sweepUnusedFiles()
        let plan = try removal.plan(selector, account: id)
        print("\(plan.messageIDs.count) message(s), \(CLI.megabytes(plan.bytes)) as the provider counts them, from \(plan.senderDomains) sender domain(s).")
        if plan.protectedLeftOut > 0 {
            print("\(plan.protectedLeftOut) protected message(s) left out: receipts, invoices, orders, payments, statements and senders you protect are never removed by a rule. `stowmail rules protected` lists your protected senders.")
        }
        if plan.protectedIncluded > 0 {
            print("\(plan.protectedIncluded) of them are protected (receipts, invoices, orders and the like). They are included because you named this \(sender != nil ? "sender" : "group") yourself.")
        }
        guard !plan.messageIDs.isEmpty else { return }
        if dryRun {
            print("Nothing removed (--dry-run).")
            return
        }
        print("Removing mail from Stow does not touch your mailbox. If you later delete old mail from your mailbox, mail you removed from Stow will then be gone for good.")
        guard yes || CLI.confirm("Remove these \(plan.messageIDs.count) message(s) from the archive?") else {
            print("Nothing removed.")
            return
        }
        let result = try removal.remove(plan.messageIDs, reason: selector.reason)
        print("Removed \(result.messages) message(s) and freed \(CLI.megabytes(result.bytesFreed)) on disk.")
        print("Sync will not download them again. `stowmail removed` lists them; `stowmail restore` brings them back while the provider still has them.")
    }
}

struct Removed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List mail removed from the archive.")

    @Option(help: "One account only (ID, prefix, address or name).") var account: String?

    func run() async throws {
        let archive = try CLIArchive.open(readOnly: true)
        let id = try account.map { try CLIArchive.accounts(archive).find($0).account.id }
        let tombstones = try ArchiveRemoval(archive: archive).tombstones(account: id)
        for tombstone in tombstones {
            let restore = tombstone.restoreRequestedAt.map { "  [restore requested \(CLI.day($0))]" } ?? ""
            print("\(tombstone.id)  \(CLI.day(tombstone.date))  \(tombstone.sender ?? "(no sender)")  \(tombstone.reason)  removed \(CLI.day(tombstone.removedAt))\(restore)")
        }
        print("\(tombstones.count) removed message(s).")
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put removed mail back: it downloads again on the next sync, if the provider still has it."
    )

    @Argument(help: "Numbers from `stowmail removed`.") var ids: [Int64] = []
    @Flag(help: "Restore everything removed (for one account with --account).") var all = false
    @Option(help: "One account only (ID, prefix, address or name).") var account: String?

    func validate() throws {
        if ids.isEmpty == !all { throw ValidationError("Give message numbers from `stowmail removed`, or --all.") }
    }

    func run() async throws {
        CLI.bootstrapLogging()
        let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
        defer { lock.release() }
        let removal = ArchiveRemoval(archive: archive)
        let id = try account.map { try CLIArchive.accounts(archive).find($0).account.id }
        let chosen = all ? try removal.tombstones(account: id).map(\.id) : ids
        let result = try removal.requestRestore(chosen)
        print("\(result.queued) message(s) will download on the next sync.")
        if result.unavailable > 0 {
            print("\(result.unavailable) could not be found where the mailbox last had them (the folder changed, or no longer syncs).")
        }
    }
}

/// The coverage date and safe-to-delete guidance (D-021, D-024, D-034).
struct Coverage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the date before which everything is archived, and what is safe to delete from the mailbox.",
        discussion: """
            Stow never deletes from your mailbox. With --retention (for example 12m or 2y), Stow remembers how long you \
            keep mail on the server, and once everything older is archived and verified it gives the steps to delete it \
            yourself. --retention none forgets the setting.
            """
    )

    @Argument(help: "Account ID, ID prefix, address or name.") var account: String
    @Option(help: "How long you keep mail in the mailbox: months (12m) or years (2y), or none.") var retention: String?

    func validate() throws {
        if let retention, Self.months(retention) == nil, retention != "none" {
            throw ValidationError("--retention takes months (12m), years (2y) or none.")
        }
    }

    static func months(_ text: String) -> Int? {
        let lower = text.lowercased()
        guard let number = Int(lower.dropLast()), number > 0 else { return nil }
        if lower.hasSuffix("m") { return number }
        if lower.hasSuffix("y") { return number * 12 }
        return nil
    }

    func run() async throws {
        CLI.bootstrapLogging()
        let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
        defer { lock.release() }
        let record = try CLIArchive.accounts(archive).find(account)
        if let retention {
            try StowStore.Coverage.setRetention(archive, account: record.account.id, months: Self.months(retention))
        }
        let report = try StowStore.Coverage.compute(archive, account: record.account.id)

        print("\(record.account.email):")
        if let date = report.coverageDate {
            print("Everything before \(CLI.day(date)) is archived and verified.")
        } else {
            print("No coverage date yet: \(report.heldBackBy ?? "sync has not finished").")
        }
        if let reason = report.heldBackBy, report.coverageDate != nil { print("Held back by \(reason).") }
        if report.unfetchable > 0 {
            print("\(report.unfetchable) message(s) were listed by the server but never returned; they hold the date back until they download or are deleted there.")
        }
        guard let months = report.retentionMonths, let cutoff = report.retentionCutoff else {
            print("Tell Stow how long you keep mail in the mailbox (for example --retention 12m) to get deletion instructions.")
            return
        }
        print("You keep \(months) month(s) of mail in the mailbox: mail before \(CLI.day(cutoff)) can go.")
        if report.atRisk > 0 {
            print("WARNING: \(report.atRisk) message(s) from before \(CLI.day(cutoff.addingTimeInterval(TimeInterval(StowStore.Coverage.warningDays * 86_400)))) are not archived yet. If your mailbox deletes old mail automatically, they could be lost. Let sync finish first.")
        }
        guard report.coversRetention, let before = report.deleteBefore else {
            print("Not yet safe: the coverage date does not reach \(CLI.day(cutoff)). Stow will offer the steps once it does.")
            return
        }
        print("Safe to delete from the mailbox: \(report.safeToDelete) message(s), \(CLI.megabytes(report.safeToDeleteBytes)).")
        print(RetentionGuide.warning(count: report.safeToDelete, bytes: report.safeToDeleteBytes, lastBackup: TimeMachineStatus.latestBackup()))
        let kind = RetentionGuide.kind(provider: record.account.provider, email: record.account.email)
        for (index, step) in RetentionGuide.steps(kind, before: before).enumerated() {
            print("  \(index + 1). \(step)")
        }
    }
}
