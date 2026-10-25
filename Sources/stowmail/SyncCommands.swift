import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowSecrets
import StowStore
import StowSync

struct Folders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List an account's folders and labels, and which ones sync downloads."
    )

    @Argument(help: "Account ID, ID prefix, address or name.")
    var account: String

    func run() async throws {
        CLI.bootstrapLogging()
        let accounts = CLIArchive.accounts(try CLIArchive.open())
        let record = try accounts.find(account)
        let profile = ProviderProfile.forProvider(record.account.provider)
        let session = try await SessionFactory(account: record.account, endpoint: profile.endpoint,
                                               tokens: try CLI.tokenProvider(accounts: accounts)).open()
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

/// R6 (D-055 step 5, D-404): what the first-run screen shows before any download.
struct Size: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List an account's mailbox and show how many emails and how much mail it holds, downloading nothing.",
        discussion: "Works before the recovery key is confirmed. Records what it lists, so the first sync starts from there."
    )

    @Argument(help: "Account ID, ID prefix, address or name.")
    var account: String

    func run() async throws {
        CLI.bootstrapLogging()
        let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
        defer { lock.release() }
        let accounts = CLIArchive.accounts(archive)
        let record = try accounts.find(account)
        guard record.isConnected else {
            throw ValidationError("That account is disconnected. Add it again with `stowmail account add` to reconnect it.")
        }
        let size = try await EngineSync(archive: archive, tokens: try CLI.tokenProvider(accounts: accounts)).mailboxSize(for: record.account)
        let count = size.messages.formatted(.number)
        let mail = ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)
        if let quota = size.quota {
            print("\(count) emails, your mail uses \(mail) of \(ByteCountFormatter.string(fromByteCount: quota.limitBytes, countStyle: .file)).")
        } else {
            print("\(count) emails, your mail uses \(size.sizesAreEstimates ? "about " : "")\(mail).")
            print(size.quotaAdvertised ? "The server offers QUOTA but did not report a storage limit." : "The server does not offer QUOTA after sign-in.")
        }
    }
}

enum ChangeCheckArgument: String, ExpressibleByArgument, CaseIterable {
    case skip, quick, full

    var check: ChangeCheck {
        switch self {
        case .skip: .skip
        case .quick: .quick
        case .full: .full
        }
    }
}

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download an account's new mail, read-only, into the encrypted archive.",
        discussion: """
            Lists new messages, then downloads them personal mail first and bulk mail last (D-028), resuming where the \
            last run stopped. Once nothing is left to download it compares archived mail with the mailbox: flags, labels, \
            and messages marked as spam or deleted there (kept in the archive either way). The background sync \
            (`stowmail daemon install`) does the same for every account without being asked.
            """
    )

    @Argument(help: "Account ID, ID prefix, address or name.")
    var account: String

    @Option(name: .long, help: "Stop after this many messages.")
    var limit: Int?

    @Option(name: .long, help: "Messages per batch.")
    var batchSize: Int = 100

    @Option(name: .long, help: "Compare archived mail with the mailbox afterwards: skip, quick (changed flags only) or full.")
    var check: ChangeCheckArgument = .full

    func validate() throws {
        if let limit, limit <= 0 { throw ValidationError("--limit must be at least 1.") }
        if batchSize <= 0 { throw ValidationError("--batch-size must be at least 1.") }
    }

    func run() async throws {
        CLI.bootstrapLogging()
        let (archive, lock) = try CLIArchive.openForWriting()
        defer { lock.release() }
        let accounts = CLIArchive.accounts(archive)
        let record = try accounts.find(account)
        guard record.isConnected else {
            throw ValidationError("That account is disconnected. Add it again with `stowmail account add` to reconnect it.")
        }
        if record.needsSignIn { throw SyncError.needsSignIn(record.account.id) }
        let syncer = try EngineSync(archive: archive, tokens: try CLI.tokenProvider(accounts: accounts)).syncer(for: record.account)

        print("Syncing \(record.account.email) into the encrypted archive at \(archive.location.root.path)")
        let started = Date()
        let report: SyncReport
        do {
            report = try await syncer.run(SyncOptions(limit: limit, batches: BatchPlanner(maxMessages: batchSize), checkChanges: check.check)) { event in
                Self.describe(event)
            }
        } catch {
            try? accounts.recordSync(record.account.id, at: Date(), error: Redact.scrub(String(describing: error)))
            throw error
        }
        try accounts.recordSync(record.account.id, at: Date(), error: nil)
        let coverage = try? StowStore.Coverage.compute(archive, account: record.account.id)

        let seconds = Int(Date().timeIntervalSince(started))
        print("Done in \(seconds) s: \(report.messagesWritten) message(s), \(CLI.megabytes(report.bytesWritten)).")
        switch report.outcome {
        case .complete, .yielded:
            print(report.remaining.queued == 0 ? "Everything listed is downloaded." : "\(report.remaining.queued) message(s) still queued (\(CLI.megabytes(report.remaining.queuedBytes))); run again to continue.")
        case .limitReached: print("Stopped at --limit. \(report.remaining.queued) message(s) still queued; run again to continue.")
        case .budgetExhausted(let used, let limit, _):
            print("Stopped: today's download budget is used (\(CLI.megabytes(used)) of \(CLI.megabytes(limit))). It frees up over the next 24 hours; run again then.")
        }
        if report.uidValidityResets > 0 {
            print("\(report.uidValidityResets) folder(s) had a UIDVALIDITY change and were listed again.")
        }
        if report.remaining.unfetchable > 0 {
            print("\(report.remaining.unfetchable) message(s) were listed but never returned on 3 separate runs, and were recorded (see `stowmail status`).")
        }
        if !report.sourceChanges.isEmpty {
            let parts = report.sourceChanges.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.rawValue)" }
            print("Changed in the mailbox since download (kept in the archive): \(parts.joined(separator: ", ")).")
        }
        if let date = coverage?.coverageDate {
            print("Everything before \(CLI.day(date)) is archived and verified.")
        }
    }

    static func describe(_ event: SyncEvent) {
        switch event {
        case .connected(let attempt):
            if attempt > 1 { Swift.print("Reconnected.") }
        case .folderPlanned(let toSync, let skipped):
            Swift.print("\(toSync) folder(s) to sync, \(skipped) skipped (see `stowmail folders`).")
        case .folderListed(let index, let total, let newMessages):
            Swift.print("Folder \(index + 1) of \(total): \(newMessages) new message(s) queued.")
        case .uidValidityChanged(let index, let old, let new):
            Swift.print("Folder \(index + 1): UIDVALIDITY changed from \(old) to \(new); listing it again.")
        case .downloading(let queued, let bytes):
            Swift.print("Downloading \(queued) message(s), about \(CLI.megabytes(bytes)), personal mail first.")
        case .batchWritten(let messages, let bytes):
            Swift.print("  archived \(messages) message(s), \(CLI.megabytes(bytes))")
        case .notDownloaded(let count):
            Swift.print("The server would not return \(count) listed message(s). They stay queued and are tried again next run; after \(AccountSyncer.defaultUnfetchableThreshold) runs like this they are recorded and passed (D-115).")
        case .unfetchableRecorded(let count):
            Swift.print("\(count) message(s) could not be fetched on \(AccountSyncer.defaultUnfetchableThreshold) separate runs and were recorded.")
        case .changesChecked(let flags, let removed):
            Swift.print("Compared with the mailbox: \(flags) flag or label update(s), \(removed) message(s) no longer there.")
        case .retrying(let delay, let attempt, let reason):
            Swift.print("Interrupted (\(reason)). Retry \(attempt) in \(Int(delay)) s.")
        }
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the archive: every message rebuilds byte for byte, every attachment and the search index are intact.",
        discussion: """
            Without --server, reads the archive only (D-042). With --server <account>, also downloads a random sample (or \
            all, with --all) of that account's messages again into memory and compares them with the archive, read-only \
            (D-121). Reports problems by number only; never prints content, subjects or addresses. Exits with status 1 if \
            anything differs.
            """
    )

    @Option(name: .long, help: "Compare an account's archived messages with the server.")
    var server: String?

    @Option(name: .long, help: "With --server: how many messages to compare.")
    var sample: Int = 100

    @Flag(name: .long, help: "With --server: compare every message.")
    var all = false

    @Option(name: .long, help: "With --server: compare the Phase 1 development store in this folder instead of the archive.")
    var out: String?

    func validate() throws {
        if sample <= 0 { throw ValidationError("--sample must be at least 1.") }
    }

    func run() async throws {
        CLI.bootstrapLogging()
        if let server { return try await compareWithServer(server) }
        let archive = try CLIArchive.open()
        print("Checking every message, attachment and the search index...")
        let report = try ArchiveVerifier(archive: archive).run { done, total in
            Swift.print("  \(done) of \(total) messages")
        }
        print("Messages: \(report.messages), rebuilt byte for byte: \(report.rebuilt).")
        print("Attachments: \(report.attachments), intact: \(report.attachments - report.failedAttachments.count).")
        for id in report.failedMessages { print("  MESSAGE DID NOT REBUILD: message \(id)") }
        for id in report.failedAttachments { print("  ATTACHMENT DAMAGED: attachment \(id)") }
        print("Search index: \(report.searchIndexConsistent ? "matches the stored text" : "DOES NOT MATCH")")
        print("Database: \(report.databaseIntegrity)\(report.foreignKeyProblems > 0 ? ", \(report.foreignKeyProblems) broken references" : "")")
        if report.unusedMessageFiles + report.unusedAttachmentFiles > 0 {
            print("Unused files left by an interrupted sync or removal: \(report.unusedMessageFiles + report.unusedAttachmentFiles) (harmless; deleted when background sync next starts, or by `stowmail remove`).")
        }
        guard report.isClean else {
            FileHandle.standardError.write(Data("Verification failed.\n".utf8))
            throw ExitCode(1)
        }
        print("The archive is intact.")
    }

    func compareWithServer(_ query: String) async throws {
        let archive = try CLIArchive.open()
        let accounts = CLIArchive.accounts(archive)
        let record = try accounts.find(query)
        if record.needsSignIn { throw SyncError.needsSignIn(record.account.id) }
        let profile = ProviderProfile.forProvider(record.account.provider)
        let factory = SessionFactory(account: record.account, endpoint: profile.endpoint, tokens: try CLI.tokenProvider(accounts: accounts))
        let source: RawMessageSource
        if let out {
            source = try FileRawMessageStore(root: CLI.storeRoot(out))
        } else {
            source = ArchiveRawSource(archive: archive, account: record.account.id)
        }
        let verifier = StoreVerifier(
            account: record.account,
            openSession: { try await factory.open() },
            source: source,
            budget: ByteBudget(limit: profile.dailyByteLimit, store: ArchiveSyncStore(archive: archive), account: record.account.id)
        )
        let report = try await verifier.run(sample: all ? nil : sample)
        print("Archived messages for this account: \(report.storedMessages). Checked: \(report.sampled).")
        print("Compared with the server: \(report.compared). Identical: \(report.identical).")
        for item in report.mismatched { print("  MISMATCH: \(item)") }
        if !report.goneFromServer.isEmpty { print("Deleted on the server since sync (not compared): \(report.goneFromServer.count)") }
        for item in report.notCompared { print("  not compared (still on the server but not returned): \(item)") }
        for (index, reason) in report.skippedFolders.sorted(by: { $0.key < $1.key }) { print("Folder \(index + 1) skipped: \(reason)") }
        guard report.isClean else {
            FileHandle.standardError.write(Data("Verification failed: \(report.mismatched.count) archived message(s) differ from the server.\n".utf8))
            throw ExitCode(1)
        }
        print(report.notCompared.isEmpty && report.skippedFolders.isEmpty ? "All checked messages match." : "No mismatches among the messages compared.")
    }
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write archived mail to mbox files, exactly as downloaded: one account, or every account with --all.",
        discussion: """
            One account: `stowmail export <account> --mbox <file>`. Everything: `stowmail export --all --mbox-dir <folder>` \
            writes one file per account, named after its address. Files are never overwritten. They are unencrypted \
            (permissions 0600): keep them somewhere safe, and delete them when done.
            """
    )

    @Argument(help: "Account ID, ID prefix, address or name.")
    var account: String?

    @Option(name: .long, help: "The mbox file to create. It must not exist yet.")
    var mbox: String?

    @Flag(name: .long, help: "Export every account, one file each, into --mbox-dir.")
    var all = false

    @Option(name: .long, help: "With --all: the folder to write into (created if missing).")
    var mboxDir: String?

    func validate() throws {
        if all {
            guard account == nil, mbox == nil, mboxDir != nil else {
                throw ValidationError("With --all, give --mbox-dir <folder> and no account or --mbox.")
            }
        } else {
            guard account != nil, mbox != nil, mboxDir == nil else {
                throw ValidationError("Give an account and --mbox <file>, or --all --mbox-dir <folder>.")
            }
        }
    }

    func run() async throws {
        CLI.bootstrapLogging()
        let archive = try CLIArchive.open(readOnly: true)
        if all, let mboxDir {
            let folder = URL(fileURLWithPath: (mboxDir as NSString).expandingTildeInPath, isDirectory: true)
            let results = try MboxExport.exportAll(archive, to: folder) { _, done, total in
                Swift.print("  \(done) of \(total)")
            }
            for result in results {
                print("Wrote \(result.messages) message(s), \(CLI.megabytes(result.bytes)), to \(result.file.lastPathComponent).")
            }
            print("\(results.count) file(s) in \(folder.path).")
            print("These files are not encrypted. Keep them safe and delete them when you no longer need them.")
            return
        }
        guard let account, let mbox else { return }
        let record = try CLIArchive.accounts(archive).find(account)
        let url = URL(fileURLWithPath: (mbox as NSString).expandingTildeInPath)
        let result = try MboxExport.export(archive, account: record.account.id, to: url) { done, total in
            Swift.print("  \(done) of \(total)")
        }
        print("Wrote \(result.messages) message(s), \(CLI.megabytes(result.bytes)), to \(url.path).")
        print("This file is not encrypted. Keep it safe and delete it when you no longer need it.")
    }
}
