import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowStore
import StowSync

struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The background sync: run it, or install it to start at login.",
        subcommands: [Run.self, Install.self, Uninstall.self],
        defaultSubcommand: Run.self
    )

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sync every account in turn, at low priority, until stopped. launchd runs this after `daemon install`.",
            discussion: """
                Pauses on battery below 20 per cent, in Low Power Mode, while the archive's disk is disconnected, and until \
                the recovery key is confirmed. Checks for new mail every five minutes once caught up.
                """
        )

        func run() async throws {
            CLI.bootstrapLogging()
            LaunchAgent.lowerPriority()
            print("Stow background sync started. Logs: \(LaunchAgent.logDirectory.path)")
            let scheduler = Scheduler(
                openArchive: { try CLIArchive.open() },
                makeSync: { archive in EngineSync(archive: archive, tokens: try CLI.tokenProvider(accounts: ArchiveAccounts(archive: archive))) }
            )
            await Task(priority: .background) { await scheduler.run() }.value
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the background sync as a launchd agent that starts now and at every login.",
            discussion: "The agent's file holds no secrets: only this program's path and a few settings, such as where the .env file is. Settings the installed agent already has are kept unless set in this shell; set one to empty to remove it."
        )

        func run() async throws {
            let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            var current = ProcessInfo.processInfo.environment.filter { LaunchAgent.allowedEnvironment.contains($0.key) }
            if current["STOW_ENV_FILE"] == nil {
                let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
                if FileManager.default.fileExists(atPath: local.path) { current["STOW_ENV_FILE"] = local.path }
            }
            let (environment, change) = LaunchAgent.reinstallEnvironment(current: current, previous: LaunchAgent.installedEnvironment())
            try LaunchAgent.install(executable: executable, environment: environment)
            print("Installed \(LaunchAgent.plistURL.path).")
            if !change.kept.isEmpty { print("Kept from the previous install: \(change.kept.joined(separator: ", ")).") }
            if !change.changed.isEmpty { print("Changed: \(change.changed.joined(separator: ", ")).") }
            if !change.removed.isEmpty { print("Removed: \(change.removed.joined(separator: ", ")).") }
            print("The background sync runs now and at every login, at low priority. `stowmail status` shows how it is doing.")
            print("It runs a copy of this program at \(LaunchAgent.installedExecutable.path), so rebuilding does not affect it.")
            print("Run `stowmail daemon install` again to update it to a new build.")
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the background sync and remove its launchd agent. The archive is kept.")

        func run() async throws {
            try LaunchAgent.uninstall()
            print("The background sync is stopped and will not start at login. Your archive is untouched.")
        }
    }
}

/// Per account: last sync, progress, downloads today, last error (step 8).
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how each account's sync is going, and the background sync.",
        discussion: "With --folders, also each synced folder's own message count on the server against what Stow has archived, queued or could not download."
    )

    @Flag(help: "Also show each synced folder: the server's count against Stow's.") var folders = false

    func run() async throws {
        let location = CLIArchive.location()
        let archive: Archive
        do {
            archive = try CLIArchive.open(readOnly: true)
        } catch let error as ArchiveLocationError {
            print(error.description)
            return
        }
        let now = Date()
        let statuses = try ArchiveStatus.collect(archive, now: now)
        if statuses.isEmpty { print("No accounts yet. Add one with `stowmail account add gmail` or `stowmail account add microsoft`.") }
        for status in statuses {
            let record = status.account
            print("\(record.account.email) (\(record.account.provider.rawValue), \(record.account.id.rawValue.prefix(8)))")
            if !record.isConnected { print("  Disconnected: no longer syncs. Its \(status.archivedMessages) archived messages are kept.") }
            if record.needsSignIn { print("  Needs sign-in: run `stowmail account signin \(record.account.id.rawValue.prefix(8))`.") }
            print("  Last sync: \(status.lastSyncAt.map(CLI.time) ?? "never")\(status.lastError == nil ? "" : " (failed)")")
            if let error = status.lastError { print("  Last error: \(error)") }
            print("  Archived: \(status.archivedMessages) messages, \(CLI.megabytes(status.archivedBytes))")
            if status.queue.queued > 0 {
                print(String(format: "  Downloading: %d to go (%@), %.0f%% done%@", status.queue.queued, CLI.megabytes(status.queue.queuedBytes),
                             status.progress * 100, status.firstSyncComplete ? "" : ", first sync in progress"))
            } else if status.firstSyncComplete {
                print("  Up to date.")
            }
            if status.queue.unfetchable > 0 {
                print("  Could not download: \(status.queue.unfetchable) message(s) the server lists but never returns (recorded after 3 runs).")
            }
            let profile = ProviderProfile.forProvider(record.account.provider)
            print("  Downloaded in the last 24 hours: \(CLI.megabytes(status.bytesLast24Hours))\(profile.dailyByteLimit.map { " of \(CLI.megabytes($0)) allowed" } ?? "")")
            if let coverage = status.coverageDate { print("  Everything before \(CLI.day(coverage)) is archived and verified.") }
            if !status.sourceStates.isEmpty {
                let parts = status.sourceStates.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.rawValue)" }
                print("  Changed in the mailbox (kept here): \(parts.joined(separator: ", ")). Spam is hidden from search.")
            }
            for error in status.folderErrors { print("  Folder problem: \(error)") }
            if folders { try Self.printFolders(archive, account: record.account.id) }
            if status.removed > 0 { print("  Removed from the archive: \(status.removed) (`stowmail removed`).") }
        }
        let heartbeat = (try? archive.meta("daemon_heartbeat")).flatMap { $0 }.flatMap(Int.init).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let daemon = LaunchAgent.isInstalled ? (LaunchAgent.isLoaded() ? "running" : "installed but not running") : "not installed (`stowmail daemon install`)"
        let pauseReason = PowerState.current().pauseReason
        // A round finishes at least every few minutes while syncing; "running" alone hid a stuck sync (D-082).
        if LaunchAgent.isLoaded(), pauseReason == nil, let heartbeat, Date().timeIntervalSince(heartbeat) > 20 * 60 {
            print("Background sync: running, but it has not finished a round since \(CLI.time(heartbeat)). The reason is in \(LaunchAgent.outputLog.path).")
        } else {
            print("Background sync: \(daemon)\(heartbeat.map { ", last active \(CLI.time($0))" } ?? "")")
        }
        if let reason = pauseReason { print("Sync is paused: \(reason).") }
        print("Archive: \(location.root.path). Logs: \(LaunchAgent.logDirectory.path)")
    }

    /// One line per synced folder. "=" when Stow accounts for every message the
    /// server counted (archived + queued + could not download), else the difference.
    static func printFolders(_ archive: Archive, account: AccountID) throws {
        let reports = try ArchiveStatus.folders(archive, account: account)
        guard !reports.isEmpty else {
            print("  Folders: none listed yet.")
            return
        }
        print("  Folders (server count | archived + queued + could not download):")
        for report in reports {
            let ours = report.archived + report.queued + report.unfetchable
            let server = report.serverCount.map(String.init) ?? "?"
            let verdict = report.serverCount == nil ? "" : report.matches ? "  =" : "  differs by \(ours - report.serverCount!)"
            let detail = [report.queued > 0 ? "\(report.queued) queued" : nil,
                          report.unfetchable > 0 ? "\(report.unfetchable) could not download" : nil,
                          report.firstSyncComplete ? nil : "first sync in progress",
                          report.lastError.map { "error: \($0)" }].compactMap { $0 }
            print("    \(report.name): \(server) | \(report.archived) archived\(verdict)\(detail.isEmpty ? "" : "  (\(detail.joined(separator: ", ")))")")
        }
        print("    (Counts are from the last listing; mail that arrived since shows as a difference until the next sync.)")
    }
}
