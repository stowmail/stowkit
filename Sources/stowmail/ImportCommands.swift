import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowSearch
import StowSecrets
import StowStore

/// `stowmail import`: mbox files (B2-06), and the development import (D-208)
/// under its own name so the two cannot be confused (D-560).
struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import mail into the encrypted archive: mbox files, or development sources.",
        subcommands: [ImportMbox.self, ImportDev.self]
    )
}

/// `stowmail import mbox <file>...` (B2-06, D-555, D-556, D-562 to D-568):
/// Google Takeout and other mbox files, into an account the user picks.
struct ImportMbox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mbox",
        abstract: "Import one or more .mbox files, such as a Google Takeout of Gmail, into an account.",
        discussion: """
            Each message is kept exactly as stored in the file once the mbox framing is undone. Choose the account the \
            mail belongs to: --account for one already in Stow, or --new-account for a mailbox that is closed or not \
            added (an import-only account, never synced). Imported mail does not move an account's "safely stowed up to" \
            date and never counts towards what is safe to delete from the mailbox. Reads the files only; opens no connection.
            --check reads the files and reports what is in them without changing the archive.
            """
    )

    @Argument(help: "The .mbox files.") var files: [String]
    @Option(help: "Import into this account (ID, prefix, address or name).") var account: String?
    @Option(help: "Import into a new import-only account with this address.") var newAccount: String?
    @Option(help: "A name for the new account, for example \"Old work\". With --new-account only.") var name: String?
    @Flag(help: "Read `>From ` quoting as mboxo instead of mboxrd (D-558). Only for files known to come from an mboxo writer.")
    var mboxo = false
    @Flag(help: "Read the files and report what is in them; import nothing.") var check = false
    @Flag(help: "Close an unfinished import of these files as it stands and begin again (messages already imported are skipped).")
    var startOver = false

    var variant: MboxVariant { mboxo ? .mboxo : .mboxrd }

    func validate() throws {
        if account != nil, newAccount != nil { throw ValidationError("Use --account or --new-account, not both.") }
        if !check, account == nil, newAccount == nil {
            throw ValidationError("Choose the account the mail belongs to: --account <account> or --new-account <address>.")
        }
        if name != nil, newAccount == nil { throw ValidationError("--name goes with --new-account.") }
        if check, startOver { throw ValidationError("--start-over imports; it does not go with --check.") }
        if let newAccount, !Self.looksLikeAddress(newAccount) {
            throw ValidationError("\(newAccount) does not look like an email address.")
        }
    }

    func run() async throws {
        CLI.bootstrapLogging()
        let urls = try Self.files(files)
        if check {
            for url in urls { try Self.report(url, variant: variant) }
            return
        }

        // The writer lock, without waiting: an import can run for hours, and
        // queueing it behind a sync round would look like a hang (D-035, D-560).
        let archive = try CLIArchive.open()
        try ArchiveSetup.requireConfirmed(archive)
        let lock: ArchiveLock
        do {
            lock = try ArchiveLock.acquire(archive.location)
        } catch ArchiveLockError.busy {
            throw ImportMboxError.archiveBusy
        }
        defer { lock.release() }
        try ArchiveSetup.finishConfirmedKey(archive)

        let record = try targetAccount(archive)
        print("Importing into \(record.account.email) (\(record.account.id.rawValue.prefix(8)))\(record.account.provider.syncs ? "" : ", import only").")
        fflush(stdout)
        let rules = try EngineRules.ruleSet(archive: archive, account: record.account.id)
        let importer = MboxImporter(archive: archive, importer: Importer(archive: archive, classifier: EngineRules.classifier(rules)))
        for url in urls {
            print("\(url.lastPathComponent):")
            fflush(stdout)
            let report = try importer.run(url, account: record.account.id, variant: variant, startOver: startOver, progress: { batch in
                print("  \(batch.messagesRead) messages read, \(Int(batch.progress * 100))% of the file...")
                fflush(stdout)
            })
            Self.describe(report, asked: variant)
        }
        let queue = try OCRQueue(archive: archive).status()
        if queue.pending > 0 { print("\(queue.pending) attachments queued for OCR; the background sync reads them, or run `stowmail ocr run`.") }
    }

    /// The account named with --account, or the import-only account --new-account makes (D-568).
    func targetAccount(_ archive: Archive) throws -> AccountRecord {
        let accounts = ArchiveAccounts(archive: archive)
        if let account { return try accounts.find(account) }
        guard let address = newAccount else { throw ValidationError("Choose the account the mail belongs to.") }
        if let existing = try accounts.all().first(where: {
            $0.account.provider == .imported && $0.account.email.lowercased() == address.lowercased()
        }) {
            throw ImportMboxError.importOnlyExists(address, existing.account.id)
        }
        let record = AccountRecord(account: Account(id: .generate(), provider: .imported, email: address, displayName: name ?? address))
        try accounts.add(record)
        print("Made an import-only account for \(address) (\(record.account.id.rawValue.prefix(8))). It never syncs and has no sign-in.")
        return record
    }

    /// One file's outcome. Counts only; the file name went to the terminal above.
    static func describe(_ report: MboxImportReport, asked: MboxVariant) {
        let batch = report.batch
        if report.alreadyImported {
            print("  Already imported on \(CLI.day(batch.finishedAt ?? batch.updatedAt)): \(batch.imported) imported, \(batch.duplicates) already in Stow, \(batch.failed) not imported. Nothing read.")
            return
        }
        if let from = report.resumedFrom, from > 0 {
            print("  Carried on from where the last run stopped (\(CLI.megabytes(from)) into the file).")
        }
        if batch.variant != asked { Swift.print("  Read as \(batch.variant.rawValue), as when this import started.") }
        print("  Done: \(batch.messagesRead) messages read: \(batch.imported) imported, \(batch.duplicates) already in Stow, \(batch.failed) not imported.")
        let reasons: [(FileDuplicate, String)] = [(.sameBytes, "the same bytes"), (.sameMessage, "the same message (Message-ID and content)"),
                                                  (.removedEarlier, "removed from the archive earlier")]
        let skipped = reasons.compactMap { reason, words in report.duplicates[reason].map { "\($0) \(words)" } }
        if !skipped.isEmpty { Swift.print("  Skipped this run: \(skipped.joined(separator: ", ")).") }
        let failures = [("cut_short", "cut short at the end of the file"), ("too_large", "larger than \(CLI.megabytes(MboxLimits.defaultMaximumMessageBytes))"),
                        ("empty", "empty"), ("not_stored", "could not be stored (see the log)")]
            .compactMap { reason, words in report.failures[reason].map { "\($0) \(words)" } }
        if !failures.isEmpty { Swift.print("  Not imported this run: \(failures.joined(separator: ", ")).") }
        if report.storedUnread > 0 {
            print("  \(report.storedUnread) kept whole without being read in time; a later Stow reads them again.")
        }
    }

    /// The files as URLs, each checked to be a readable regular file, no file named twice.
    static func files(_ paths: [String]) throws -> [URL] {
        var seen: Set<String> = []
        return try paths.map { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            _ = try MboxScan.checkFile(url)
            let identity = url.resolvingSymlinksInPath().path
            guard seen.insert(identity).inserted else { throw ImportMboxError.namedTwice(path) }
            return url
        }
    }

    static func looksLikeAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !text.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" })
    }

    /// `--check`: counts for one file. File names are the user's own and go to the terminal only, never the log (D-040).
    static func report(_ url: URL, variant: MboxVariant) throws {
        print("\(url.lastPathComponent):")
        fflush(stdout)
        let report = try MboxScan.scan(url, variant: variant) { counts in
            print("  \(counts.messages) messages read...")
        }
        let counts = report.counts
        print("  \(counts.messages) messages, \(CLI.megabytes(report.messageBytes)) of mail in a \(CLI.megabytes(report.fileBytes)) file (read as \(variant.rawValue))")
        var notes: [String] = []
        if counts.cutShort > 0 { notes.append("\(counts.cutShort) cut short at the end of the file (would not be imported)") }
        if counts.tooLarge > 0 { notes.append("\(counts.tooLarge) larger than \(CLI.megabytes(MboxLimits.defaultMaximumMessageBytes)) (would not be imported)") }
        if counts.empty > 0 { notes.append("\(counts.empty) empty (would not be imported)") }
        if counts.withNUL > 0 { notes.append("\(counts.withNUL) holding NUL bytes (kept as they are)") }
        if counts.fromLinesKept > 0 { notes.append("\(counts.fromLinesKept) lines starting \"From \" kept inside messages") }
        if counts.separatorsWithoutBlankLine > 0 {
            notes.append("\(counts.separatorsWithoutBlankLine) of them look like the start of a message with no blank line before; tell us if messages seem joined")
        }
        if counts.bytesBeforeFirstMessage > 0 { notes.append("\(counts.bytesBeforeFirstMessage) blank bytes before the first message, skipped") }
        print("  \(counts.withCRLF) with CR LF line endings, \(counts.linesUnquoted) quoted \">From\" lines unquoted")
        for note in notes { print("  \(note)") }
    }
}

enum ImportMboxError: Error, Equatable, CustomStringConvertible {
    case archiveBusy
    case importOnlyExists(String, AccountID)
    case namedTwice(String)

    var description: String {
        switch self {
        case .archiveBusy:
            "Another Stow process, probably the background sync, is writing to the archive, so the import did not start. "
                + "Try again when its turn ends, or stop it with `stowmail daemon uninstall` and install it again afterwards."
        case .importOnlyExists(_, let id):
            "That address already has an import-only account (\(id.rawValue.prefix(8))). Import into it with --account \(id.rawValue.prefix(8))."
        case .namedTwice(let path): "\(path) is named twice."
        }
    }
}

/// `stowmail import dev <dir>`: from a Phase 1 file store (D-015), or a folder
/// of .eml files with `--eml`. Was `stowmail import <dir>` before D-560.
struct ImportDev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Development only: import a Phase 1 development store, or a folder of .eml files.",
        discussion: """
            <dir> is a development store written by Phase 1's `stowmail sync`; its accounts must be in the archive \
            (`stowmail init` moves them in). Sync can then carry on from it without downloading those messages again. \
            With --eml, <dir> is a folder of .eml files imported into one placeholder account, for development and benchmarks.
            """
    )

    @Argument(help: "Folder to import from.") var directory: String
    @Flag(help: "Treat <dir> as a plain folder of .eml files.") var eml = false
    @Flag(help: "Skip attachment text extraction (for measuring import speed only).") var noExtraction = false

    func run() async throws {
        CLI.bootstrapLogging()
        let (archive, lock) = try CLIArchive.openForWriting()
        defer { lock.release() }
        let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        let rules = try EngineRules.ruleSet(archive: archive, account: nil)
        let importer = Importer(archive: archive, extractText: !noExtraction, classifier: EngineRules.classifier(rules))
        let progress: @Sendable (ImportSummary) -> Void = { summary in print("  \(summary)") }

        let summary: ImportSummary
        if eml {
            let account = AccountID(rawValue: "eml-import")
            try archive.register(PlaceholderAccount.make(account, provider: .microsoft))
            summary = try await importer.importAll(from: try EMLDirectorySource(directory: url, accountID: account), progress: progress)
        } else {
            let store = try FileRawMessageStore(root: url)
            let accounts = CLIArchive.accounts(archive)
            for id in Set(try await store.listKeys().map(\.accountID)) where try accounts.record(id) == nil {
                throw ValidationError("Account \(id) is not in the archive. Run `stowmail init` to move Phase 1 accounts in, or add it with `stowmail account add`.")
            }
            summary = try await importer.importAll(from: store, progress: progress)
        }
        print(summary)
        let queue = try OCRQueue(archive: archive).status()
        if queue.pending > 0 { print("\(queue.pending) attachments queued for OCR; run `stowmail ocr run`.") }
    }
}

extension CLI {
    /// One line for `stowmail status` about an import that has not reached the end of its file (D-564).
    static func unfinishedImport(_ batch: ImportBatch) -> String {
        "Unfinished import of \(URL(fileURLWithPath: batch.filePath).lastPathComponent), started \(CLI.time(batch.startedAt)): "
            + "\(Int(batch.progress * 100))% of the file, \(batch.imported) imported, \(batch.duplicates) already in Stow, "
            + "\(batch.failed) not imported. Run the same `stowmail import mbox` again to carry on."
    }
}
