import ArgumentParser
import Foundation
import StowEngine
import StowStore

/// `stowmail restore-pre-upgrade` (D-606 item 5, D-608): puts back the copy of
/// the database Stow kept from before the last format update. Command line
/// only; the app never offers it.
struct RestorePreUpgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore-pre-upgrade",
        abstract: "Put back the copy of the archive's database kept from before the last update changed its format.",
        discussion: """
            For when an update damaged the archive. Stow keeps that copy for 7 days. The database in use now is kept \
            aside for 7 days as replaced-by-restore-<date>.db. Messages and attachments are not touched; mail tidy-up \
            removed since the copy was made is listed afterwards. Needs the background sync stopped \
            (`stowmail daemon uninstall`) and the app quit. Asks first unless --yes is given.
            """
    )

    @Flag(help: "Do not ask for confirmation (for scripts).") var yes = false

    func run() async throws {
        CLI.bootstrapLogging()
        let location = CLIArchive.location()
        try ArchiveOpening.requireArchive(at: location)
        // Only a background sync that uses this archive matters; one pinned elsewhere does not.
        let agentArchive = ArchiveLocation.fromEnvironment(LaunchAgent.installedEnvironment())
        if LaunchAgent.isLoaded(), agentArchive.root.resolvingSymlinksInPath() == location.root.resolvingSymlinksInPath() {
            throw ValidationError("The background sync is running. Stop it with `stowmail daemon uninstall`, quit the Stow app, then run this again. Nothing was changed.")
        }
        let keys = try CLI.keyManager().loadKeys()
        let plan = try PreUpgradeRestore.plan(location, keys: keys)
        print("""
            This puts back the copy of your archive's database from before the \(plan.from) to \(plan.to) update \
            (updated on \(CLI.day(plan.migratedAt))), in \(location.root.path).
            The database in use now is kept aside for 7 days as replaced-by-restore-<date>.db.
            Anything Stow archived since the update is no longer listed; the next sync downloads it again.
            This version of Stow updates the archive again the next time it writes to it, so install the version \
            the release notes name before you start the background sync or the app.
            """)
        guard yes || CLI.confirm("Put the copy back?") else {
            print("Nothing was changed.")
            return
        }
        let outcome = try PreUpgradeRestore.restore(location, keys: keys)
        print("Put back the copy from before the \(plan.from) to \(plan.to) update. The replaced database is \(outcome.replacedName), kept for 7 days.")
        let report = outcome.report
        print("Checked \(report.messages) messages: \(report.rebuilt) rebuilt byte for byte, \(report.attachments) attachments.")
        if !outcome.missingFiles.isEmpty {
            let count = outcome.missingFiles.count
            print("\(count) \(count == 1 ? "message is" : "messages are") listed but \(count == 1 ? "its file was" : "their files were") removed by tidy-up after the copy was made. They show in search but cannot be opened. IDs: \(outcome.missingFiles.map(String.init).joined(separator: ", ")).")
        }
        let otherFailures = report.failedMessages.count - outcome.missingFiles.count
        if otherFailures > 0 || !report.failedAttachments.isEmpty || !report.searchIndexConsistent
            || report.databaseIntegrity != "ok" || report.foreignKeyProblems > 0 {
            print("The check found other problems too. Run `stowmail verify` for details.")
        }
    }
}
