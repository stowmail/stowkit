import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowSearch
import StowSecrets
import StowStore

/// `stowmail import <dir>`: from a Phase 1 file store (D-015), or a folder of .eml files with `--eml`.
struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import raw messages into the encrypted archive.",
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

/// Imports from a plain folder of .eml files go to one clearly fake account,
/// in the reserved `.invalid` domain (D-208).
enum PlaceholderAccount {
    static func make(_ id: AccountID, provider: Provider) -> Account {
        Account(id: id, provider: provider, email: "\(id.rawValue)@unregistered.invalid", displayName: "Imported")
    }
}

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show message, attachment, deduplication and size counts, and the archive's size against the provider's."
    )

    @Option(help: "One account only (ID, prefix, address or name).") var account: String?

    func run() async throws {
        let archive = try CLIArchive.open(readOnly: true)
        let id = try account.map { try CLIArchive.accounts(archive).find($0).account.id }
        let stats = try ArchiveStats.collect(archive, account: id)
        let mb = CLIArchive.megabytes
        print("Accounts:            \(stats.accounts)")
        print("Messages:            \(stats.messages) (\(stats.degradedMessages) degraded, \(stats.failedMessages) failed to parse)")
        print("Stored as:           \(stats.skeletonMessages) skeletons, \(stats.wholeMessages) whole; \(stats.attachmentsKeptInline) attachment(s) kept inline")
        print("Provider's size:     \(mb(stats.rawBytes)) (what the server reports for these messages)")
        print("Message files:       \(mb(stats.rawStoredBytes)) (skeletons and whole messages, compressed and encrypted)")
        print("Attachments:         \(stats.attachmentReferences) references, \(stats.distinctAttachments) distinct files")
        print("Attachment bytes:    \(mb(stats.attachmentBytesReferenced)) referenced, \(mb(stats.attachmentBytesDistinct)) stored once, \(mb(stats.dedupSavedBytes)) saved by dedup")
        print("Attachment files:    \(mb(stats.attachmentStoredBytes)) on disk")
        print("Database:            \(mb(stats.databaseBytes))\(id == nil ? "" : " (whole archive)")")
        print(String(format: "Archive total:       %@, %.2f times the provider's size", mb(stats.totalStoredBytes), stats.storedRatio))
        print("OCR pending:         \(stats.ocrPending)")
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search the archive, or with no query list the newest mail.",
        discussion: """
            Free text with "phrases", prefix*, OR and -exclusions, plus filters: from: to: subject: \
            has:attachment -has:attachment account:<id> after:YYYY-MM-DD before:YYYY-MM-DD in:<folder or label>. \
            Mail marked as spam in the mailbox is left out; add in:spam for only that, or in:anywhere for everything. \
            --folders lists the names in: accepts.
            """
    )

    @Argument(help: "The query. Leave out to list the newest mail.") var query = ""
    @Option(help: "Maximum results.") var limit = 20
    @Option(help: "Skip this many results first.") var offset = 0
    @Flag(help: "List the folders and labels in: can filter by, instead of searching.") var folders = false
    @Option(help: "Suggest senders starting with this, as the app's From token does, instead of searching.") var senders: String?

    func run() async throws {
        let archive = try CLIArchive.open(readOnly: true)
        let searcher = MessageSearcher(archive: archive)
        if let senders {
            let start = Date()
            let found = try await searcher.senderSuggestions(prefix: senders, accounts: [], limit: limit)
            let elapsed = Date().timeIntervalSince(start)
            for suggestion in found {
                let name = suggestion.sender.name.map { "\($0) " } ?? ""
                print("\(name)<\(suggestion.sender.address)>  \(suggestion.messageCount)")
            }
            print("\(found.count) sender(s) in \(Int(elapsed * 1000)) ms")
            return
        }
        if folders {
            let accounts = CLIArchive.accounts(archive)
            for folder in try await searcher.folders(accounts: []) {
                let owner = (try? accounts.find(folder.accountID.rawValue))?.account.email ?? folder.accountID.rawValue
                print("\(folder.id)  \(owner)  \(folder.kind.rawValue)  \(folder.name)\(folder.specialUse.map { "  (\($0))" } ?? "")")
            }
            return
        }
        var parsed = QueryParser.parse(query, limit: limit)
        parsed.offset = offset
        let start = Date()
        let hits = try await searcher.search(parsed)
        let searched = Date().timeIntervalSince(start)
        let total = try await searcher.count(parsed)
        let counted = Date().timeIntervalSince(start) - searched
        print(total == 1 ? "1 email" : "\(total) emails")
        if let notice = parsed.limitsApplied.notice { print(notice) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for hit in hits {
            let from = hit.from.map { $0.name ?? $0.address } ?? "(no sender)"
            let flags = [hit.hasAttachments ? "attachments" : nil, hit.ocrPending ? "OCR pending" : nil].compactMap { $0 }
            print("\(hit.messageID)  \(formatter.string(from: hit.date))  \(from)  \(hit.subject ?? "(no subject)")\(flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]")")
            // With no text the snippet is just the subject again.
            if hit.snippet != (hit.subject ?? "") { print("    \(hit.snippet)") }
        }
        print(String(format: "%d shown in %.0f ms, counted in %.0f ms", hits.count, searched * 1000, counted * 1000))
    }
}

struct ThreadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thread",
        abstract: "Show the conversation around one email, oldest first.",
        discussion: "Takes a message ID from `stowmail search`. Spam in the conversation is left out unless the email itself is spam."
    )

    @Argument(help: "Message ID.") var message: Int64

    func run() async throws {
        let archive = try CLIArchive.open(readOnly: true)
        guard let thread = try await MessageSearcher(archive: archive).thread(of: message) else {
            throw ValidationError("No message with ID \(message).")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let shown = thread.truncated ? ", showing \(thread.messages.count) around this one" : ""
        print("\(thread.totalCount) \(thread.totalCount == 1 ? "email" : "emails") in this conversation\(shown)")
        for (index, item) in thread.messages.enumerated() {
            let from = item.from.map { $0.name ?? $0.address } ?? "(no sender)"
            let marks = [item.hasAttachments ? "attachments" : nil, item.sourceState == .present ? nil : item.sourceState.rawValue]
                .compactMap { $0 }
            print("\(index == thread.selectedIndex ? ">" : " ") \(item.messageID)  \(formatter.string(from: item.date))  \(from)  \(item.subject ?? "(no subject)")\(marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]")")
        }
    }
}

struct OCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Text recognition for scanned PDFs and images.",
        subcommands: [Status.self, Run.self]
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the OCR queue.")

        func run() async throws {
            print(try OCRQueue(archive: try CLIArchive.open(readOnly: true)).status())
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Work through the OCR queue at background priority.")

        @Option(help: "Stop after this many items.") var limit: Int?

        func run() async throws {
            let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
            defer { lock.release() }
            let queue = OCRQueue(archive: archive)
            let start = Date()
            let processed = try await queue.run(limit: limit ?? .max)
            print(String(format: "Processed %d items in %.1f s. Queue: %@", processed, Date().timeIntervalSince(start),
                         try queue.status().description))
        }
    }
}
