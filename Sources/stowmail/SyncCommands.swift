import ArgumentParser
import Foundation
import StowCore
import StowSecrets
import StowSync

struct Folders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List an account's folders and labels, and which ones sync downloads."
    )

    @Argument(help: "Account ID, ID prefix, address or name.")
    var account: String

    func run() async throws {
        CLI.bootstrapLogging()
        let record = try CLI.registry().find(account)
        let profile = ProviderProfile.forProvider(record.account.provider)
        let session = try await SessionFactory(account: record.account, endpoint: profile.endpoint, tokens: try CLI.tokenProvider()).open()
        do {
            let capabilities = try await session.capabilities()
            let folders = try await session.listFolders()
            await session.logout()
            let plan = try FolderPlanner.plan(provider: record.account.provider, folders: folders, capabilities: capabilities)
            print("\(folders.count) folders and labels.")
            print("Synced:")
            for folder in plan.toSync {
                print("  \(folder.name)\(folder.specialUse.map { "  (\($0))" } ?? "")")
            }
            print("Not synced:")
            for skipped in plan.skipped {
                print("  \(skipped.folder.name)  - \(skipped.reason)")
            }
        } catch {
            await session.disconnect()
            throw error
        }
    }
}

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download every message of an account, read-only, into the development store.",
        discussion: """
        Resumes from where the last run stopped. Writes unencrypted .eml files (D-015), so the \
        folder is excluded from Time Machine and Spotlight first, and sync refuses to run if it cannot be.
        """
    )

    @Argument(help: "Account ID, ID prefix, address or name.")
    var account: String

    @Option(name: .long, help: "Stop after this many messages.")
    var limit: Int?

    @Option(name: .long, help: "Development store folder (default: \(DevStoreProtection.defaultRoot.path)). Must end in .noindex.")
    var out: String?

    @Option(name: .long, help: "Messages per batch.")
    var batchSize: Int = 100

    func validate() throws {
        if let limit, limit <= 0 { throw ValidationError("--limit must be at least 1.") }
        if batchSize <= 0 { throw ValidationError("--batch-size must be at least 1.") }
    }

    func run() async throws {
        CLI.bootstrapLogging()
        let record = try CLI.registry().find(account)
        if record.needsSignIn { throw SyncError.needsSignIn(record.account.id) }

        // Brief step 8: protect the folder, then refuse unless every protection holds.
        let root = CLI.storeRoot(out)
        let protection = DevStoreProtection()
        try protection.protect(root)
        try protection.requireProtected(root)
        try protection.protectStateDirectory(DevStoreProtection.defaultStateDirectory)

        let profile = ProviderProfile.forProvider(record.account.provider)
        let store = try FileRawMessageStore(root: root)
        let budget = ByteBudget(
            limit: profile.dailyByteLimit,
            fileURL: DevStoreProtection.defaultStateDirectory.appendingPathComponent("\(record.account.id).budget.json")
        )
        let factory = SessionFactory(account: record.account, endpoint: profile.endpoint, tokens: try CLI.tokenProvider())
        let syncer = AccountSyncer(
            account: record.account,
            openSession: { try await factory.open() },
            sink: store,
            checkpoints: store,
            budget: budget,
            unfetchable: UnfetchableLedger(
                fileURL: UnfetchableLedger.fileURL(stateDirectory: DevStoreProtection.defaultStateDirectory, accountID: record.account.id)
            )
        )

        print("Syncing \(record.account.email) into \(root.path)")
        let started = Date()
        let report = try await syncer.run(SyncOptions(limit: limit, batches: BatchPlanner(maxMessages: batchSize))) { event in
            switch event {
            case .connected(let attempt):
                if attempt > 1 { print("Reconnected.") }
            case .folderPlanned(let toSync, let skipped):
                print("\(toSync) folder(s) to sync, \(skipped) skipped (see `stowmail folders`).")
            case .folderStarted(let index, let total, let newMessages):
                print("Folder \(index + 1) of \(total): \(newMessages) new message(s).")
            case .uidValidityChanged(let index, let old, let new):
                print("Folder \(index + 1): UIDVALIDITY changed from \(old) to \(new); downloading it again.")
            case .batchWritten(let messages, let bytes, let highestUID):
                print("  wrote \(messages) message(s), \(CLI.megabytes(bytes)), up to UID \(highestUID)")
            case .folderStopped(let index, let count):
                print("Folder \(index + 1): the server would not return \(count) listed message(s). Stopped this folder before them; after \(UnfetchableLedger.defaultThreshold) runs like this they are recorded and passed (D-115).")
            case .unfetchableRecorded(let index, let count):
                print("Folder \(index + 1): \(count) message(s) could not be fetched on \(UnfetchableLedger.defaultThreshold) separate runs and were recorded; moving past them.")
            case .retrying(let delay, let attempt, let reason):
                print("Interrupted (\(reason)). Retry \(attempt) in \(Int(delay)) s.")
            }
        }
        let seconds = Int(Date().timeIntervalSince(started))
        print("Done in \(seconds) s: \(report.messagesWritten) message(s), \(CLI.megabytes(report.bytesWritten)).")
        switch report.outcome {
        case .complete: print(report.notDownloaded.isEmpty ? "Everything is downloaded." : "Finished, but some folders are incomplete (below).")
        case .limitReached: print("Stopped at --limit. Run again to continue.")
        case .budgetExhausted(let used, let limit):
            print("Stopped: today's download budget is used (\(CLI.megabytes(used)) of \(CLI.megabytes(limit))). Run again tomorrow to continue.")
        }
        if report.uidValidityResets > 0 {
            print("\(report.uidValidityResets) folder(s) had a UIDVALIDITY change and were downloaded again.")
        }
        let recorded = report.recordedUnfetchable.values.reduce(0, +)
        if recorded > 0 {
            print("\(recorded) message(s) could not be fetched and were recorded (see `stowmail doctor`).")
        }
        if !report.notDownloaded.isEmpty {
            throw SyncError.messagesNotDownloaded(folders: report.notDownloaded.count, messages: report.notDownloaded.values.reduce(0, +))
        }
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-fetch stored messages read-only and check they match the server byte for byte.",
        discussion: """
        Picks a random sample of the account's stored messages, downloads them again into memory \
        (never to disk), and compares SHA-256s with the stored files. Also checks each stored file is \
        as long as the RFC822.SIZE saved with it. Reports problems by folder number, UIDVALIDITY and \
        UID only; never prints content, subjects or addresses (D-121).
        """
    )

    @Argument(help: "Account ID, ID prefix, address or name.")
    var account: String

    @Option(name: .long, help: "How many stored messages to check.")
    var sample: Int = 100

    @Flag(name: .long, help: "Check every stored message instead of a sample.")
    var all = false

    @Option(name: .long, help: "Development store folder (default: \(DevStoreProtection.defaultRoot.path)).")
    var out: String?

    func validate() throws {
        if sample <= 0 { throw ValidationError("--sample must be at least 1.") }
    }

    func run() async throws {
        CLI.bootstrapLogging()
        let record = try CLI.registry().find(account)
        if record.needsSignIn { throw SyncError.needsSignIn(record.account.id) }
        let root = CLI.storeRoot(out)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ValidationError("No development store at \(root.path).")
        }
        let profile = ProviderProfile.forProvider(record.account.provider)
        let factory = SessionFactory(account: record.account, endpoint: profile.endpoint, tokens: try CLI.tokenProvider())
        let verifier = StoreVerifier(
            account: record.account,
            openSession: { try await factory.open() },
            source: try FileRawMessageStore(root: root),
            budget: ByteBudget(
                limit: profile.dailyByteLimit,
                fileURL: DevStoreProtection.defaultStateDirectory.appendingPathComponent("\(record.account.id).budget.json")
            )
        )
        let report = try await verifier.run(sample: all ? nil : sample)
        print("Stored messages for this account: \(report.storedMessages). Checked: \(report.sampled).")
        print("Compared with the server: \(report.compared). Identical: \(report.identical).")
        for item in report.mismatched { print("  MISMATCH: \(item)") }
        for item in report.localSizeMismatches { print("  STORED FILE LENGTH DIFFERS FROM ITS RFC822.SIZE: \(item)") }
        if !report.goneFromServer.isEmpty { print("Deleted on the server since sync (not compared): \(report.goneFromServer.count)") }
        for item in report.notCompared { print("  not compared (server did not return it intact): \(item)") }
        for (index, reason) in report.skippedFolders.sorted(by: { $0.key < $1.key }) { print("Folder \(index + 1) skipped: \(reason)") }
        guard report.isClean else {
            throw ValidationError("Verification found \(report.mismatched.count) mismatched and \(report.localSizeMismatches.count) wrong-length stored message(s).")
        }
        print(report.notCompared.isEmpty && report.skippedFolders.isEmpty ? "All checked messages match." : "No mismatches among the messages compared.")
    }
}
