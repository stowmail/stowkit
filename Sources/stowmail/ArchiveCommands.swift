import ArgumentParser
import Foundation
import StowCore
import StowSearch
import StowSecrets
import StowStore

/// Opening the archive from the CLI: location from `STOW_ARCHIVE_DIR` (else
/// `~/Library/Application Support/Stow/`), keys from the Keychain (D-208).
enum CLIArchive {
    /// `STOW_KEYCHAIN_SERVICE` lets development and tests keep their keys apart
    /// from the real archive's. Unset means the normal service.
    static func keyManager() -> KeyManager {
        let environment = ProcessInfo.processInfo.environment
        let service = environment["STOW_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 } ?? KeychainStore.defaultService
        return KeyManager(keychain: KeychainStore(service: service))
    }

    static func open(readOnly: Bool = false) throws -> Archive {
        let location = ArchiveLocation.fromEnvironment()
        guard location.exists else {
            throw ValidationError("No archive at \(location.root.path). Run `stowmail init` first.")
        }
        return try Archive.open(location, keys: try keyManager().loadKeys(), readOnly: readOnly)
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// Creates the archive keys and an empty archive.
struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create the archive keys in the Keychain and an empty encrypted archive."
    )

    func run() async throws {
        let location = ArchiveLocation.fromEnvironment()
        let manager = CLIArchive.keyManager()
        let keys: ArchiveKeys
        if try manager.keysExist() {
            keys = try manager.loadKeys()
            print("Archive keys already in the Keychain; using them.")
        } else {
            if location.exists {
                throw ValidationError("An archive exists at \(location.root.path) but its keys are not in the Keychain. Refusing to create new keys, which could never open it.")
            }
            keys = try manager.createKeys()
            print("Created archive keys in the Keychain.")
        }
        let archive = try Archive.open(location, keys: keys)
        print("Archive ready at \(archive.location.root.path)")
    }
}

/// `stowmail import <dir>`: from a file sink (D-015), or a folder of .eml files with `--eml`.
struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import raw messages into the encrypted archive.",
        discussion: """
            <dir> is a FileRawMessageStore folder written by `stowmail sync`. Accounts not yet in the archive are \
            added with a placeholder address until account registration lands (D-208). With --eml, <dir> is a \
            folder of .eml files imported into one placeholder account.
            """
    )

    @Argument(help: "Folder to import from.") var directory: String
    @Flag(help: "Treat <dir> as a plain folder of .eml files.") var eml = false
    @Flag(help: "Skip attachment text extraction (for measuring import speed only).") var noExtraction = false

    func run() async throws {
        let archive = try CLIArchive.open()
        let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        let importer = Importer(archive: archive, extractText: !noExtraction)
        let progress: @Sendable (ImportSummary) -> Void = { summary in print("  \(summary)") }

        let summary: ImportSummary
        if eml {
            let account = AccountID(rawValue: "eml-import")
            try archive.register(PlaceholderAccount.make(account, provider: .microsoft))
            summary = try await importer.importAll(from: try EMLDirectorySource(directory: url, accountID: account), progress: progress)
        } else {
            let store = try FileRawMessageStore(root: url)
            for key in Set(try await store.listKeys().map(\.accountID)) where !(try archive.accountExists(key)) {
                let sample = try await store.listKeys().first { $0.accountID == key }
                let provider: Provider = sample?.folder.hasPrefix("[Gmail]") == true ? .gmail : .microsoft
                try archive.register(PlaceholderAccount.make(key, provider: provider))
                print("Registered account \(key) with a placeholder address (unregistered.invalid).")
            }
            summary = try await importer.importAll(from: store, progress: progress)
        }
        print(summary)
        let queue = try OCRQueue(archive: archive).status()
        if queue.pending > 0 { print("\(queue.pending) attachments queued for OCR; run `stowmail ocr run`.") }
    }
}

/// Until account registration exists in the archive (Phase 2), imported
/// accounts get a clearly fake address in the reserved `.invalid` domain.
enum PlaceholderAccount {
    static func make(_ id: AccountID, provider: Provider) -> Account {
        Account(id: id, provider: provider, email: "\(id.rawValue)@unregistered.invalid", displayName: "Imported")
    }
}

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show message, attachment, deduplication and size counts.")

    func run() async throws {
        let stats = try ArchiveStats.collect(try CLIArchive.open(readOnly: true))
        let mb = CLIArchive.megabytes
        print("Accounts:            \(stats.accounts)")
        print("Messages:            \(stats.messages) (\(stats.degradedMessages) degraded, \(stats.failedMessages) failed to parse)")
        print("Raw messages:        \(mb(stats.rawBytes)) original, \(mb(stats.rawStoredBytes)) stored")
        print("Attachments:         \(stats.attachmentReferences) references, \(stats.distinctAttachments) distinct files")
        print("Attachment bytes:    \(mb(stats.attachmentBytesReferenced)) referenced, \(mb(stats.attachmentBytesDistinct)) stored once, \(mb(stats.dedupSavedBytes)) saved by dedup")
        print("Attachment files:    \(mb(stats.attachmentStoredBytes)) on disk")
        print("OCR pending:         \(stats.ocrPending)")
        print("Database:            \(mb(stats.databaseBytes))")
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search the archive.",
        discussion: """
            Free text with "phrases", prefix*, OR and -exclusions, plus filters: from: to: subject: \
            has:attachment -has:attachment account:<id> after:YYYY-MM-DD before:YYYY-MM-DD.
            """
    )

    @Argument(help: "The query.") var query: String
    @Option(help: "Maximum results.") var limit = 20

    func run() async throws {
        let archive = try CLIArchive.open(readOnly: true)
        let start = Date()
        let hits = try await MessageSearcher(archive: archive).search(QueryParser.parse(query, limit: limit))
        let elapsed = Date().timeIntervalSince(start)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for hit in hits {
            let from = hit.from.map { $0.name ?? $0.address } ?? "(no sender)"
            let flags = [hit.hasAttachments ? "attachments" : nil, hit.ocrPending ? "OCR pending" : nil].compactMap { $0 }
            print("\(hit.messageID)  \(formatter.string(from: hit.date))  \(from)  \(hit.subject ?? "(no subject)")\(flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]")")
            print("    \(hit.snippet)")
        }
        print(String(format: "%d results in %.0f ms", hits.count, elapsed * 1000))
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
            let queue = OCRQueue(archive: try CLIArchive.open())
            let start = Date()
            let processed = try await queue.run(limit: limit ?? .max)
            print(String(format: "Processed %d items in %.1f s. Queue: %@", processed, Date().timeIntervalSince(start),
                         try queue.status().description))
        }
    }
}
