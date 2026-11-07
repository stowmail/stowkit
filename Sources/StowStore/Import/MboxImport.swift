import CryptoKit
import Foundation
import GRDB
import Logging
import StowCore

/// Why an mbox import did not start or stopped. Paths go to the terminal only (D-040).
public enum MboxImportError: Error, Equatable, CustomStringConvertible {
    /// An unfinished import of this path found a different file there (D-564).
    case fileChanged(String)
    /// The account is not in the archive.
    case unknownAccount(AccountID)

    public var description: String {
        switch self {
        case .fileChanged(let path):
            "\(path) changed since its import started, so it cannot carry on from where it stopped. Put the original file back, or run again with --start-over to begin a new import of this file (messages already imported are skipped)."
        case .unknownAccount(let id): "Account \(id) is not in the archive."
        }
    }
}

/// One file's import batch as stored (`import_batches`, D-562, D-564). Counts and dates only.
public struct ImportBatch: Sendable, Equatable {
    public var id: Int64
    public var account: AccountID
    /// As given. Shown in the terminal only, never logged above debug (D-040).
    public var filePath: String
    public var fileSize: Int64
    public var variant: MboxVariant
    public var committedOffset: Int64
    public var messagesRead = 0
    public var imported = 0
    /// Skipped by the duplicate rule (D-565), including messages removed earlier.
    public var duplicates = 0
    public var failed = 0
    public var bytesRead: Int64 = 0
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    /// The identity it was started with (D-564), compared on resume.
    var storedHead = Data()
    var storedModifiedAt: Int64 = 0

    /// Share of the file read so far, 0 to 1.
    public var progress: Double { fileSize == 0 ? 1 : min(1, Double(committedOffset) / Double(fileSize)) }
}

/// What one run of `stowmail import mbox` did for one file.
public struct MboxImportReport: Sendable, Equatable {
    public var batch: ImportBatch
    /// The file was imported before, so it was not read again.
    public var alreadyImported = false
    /// The offset this run carried on from, when it resumed an unfinished import.
    public var resumedFrom: Int64?
    /// This run's skipped messages by reason (the batch keeps only the total).
    public var duplicates: [FileDuplicate: Int] = [:]
    /// This run's failures by reason (`import_failures.reason`).
    public var failures: [String: Int] = [:]
    /// Messages this run stored whole without reading them in time (D-502).
    public var storedUnread = 0
}

/// Imports mbox files into one account (B2-06, D-556, D-562 to D-566).
///
/// Each file is one batch. Every message's outcome is committed with the
/// batch's new offset and counts in one transaction, so stopping at any point
/// loses at most the message being read, and running again carries on from
/// the offset. Reads the local file only; opens no connection.
public struct MboxImporter: Sendable {
    public let archive: Archive
    public let importer: Importer
    /// Messages between progress reports.
    public var progressEvery = 1_000
    /// Tests only: stop after this many messages, between two commits, as a kill would.
    var stopAfter: Int?
    static let headBytes = 1_048_576
    let logger = Logger(label: "ee.getstow.store.mbox-import")

    public init(archive: Archive, importer: Importer) {
        self.archive = archive
        self.importer = importer
    }

    /// Imports `url` into `account`. A file imported before is not read again;
    /// an unfinished import of the same file carries on, with the variant it
    /// started with. `startOver` closes an unfinished import of this path
    /// first, as it stands, and begins a new one.
    public func run(
        _ url: URL, account: AccountID, variant: MboxVariant = .mboxrd, startOver: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init, progress: ((ImportBatch) -> Void)? = nil
    ) throws -> MboxImportReport {
        let path = url.standardizedFileURL.path
        let identity = try Self.identity(of: url)
        guard try ArchiveAccounts(archive: archive).record(account) != nil else { throw MboxImportError.unknownAccount(account) }

        var report = try archive.database.write { db -> MboxImportReport in
            let unfinished = try Self.batches(db, sql: "account_id = ? AND finished_at IS NULL", [account.rawValue])
            let changed = unfinished.filter { $0.filePath == path && !identity.matches($0) }
            if !changed.isEmpty {
                guard startOver else { throw MboxImportError.fileChanged(path) }
            }
            if startOver {
                for batch in unfinished where batch.filePath == path || identity.matches(batch) {
                    try db.execute(sql: "UPDATE import_batches SET finished_at = ?, updated_at = ? WHERE id = ?",
                                   arguments: [Int(now().timeIntervalSince1970), Int(now().timeIntervalSince1970), batch.id])
                }
            } else {
                if let same = unfinished.first(where: identity.matches) {
                    return MboxImportReport(batch: same, resumedFrom: same.committedOffset)
                }
                if let done = try Self.batches(db, sql: "account_id = ? AND finished_at IS NOT NULL AND head_sha256 = ? AND file_size = ?",
                                               [account.rawValue, identity.head, identity.size]).last {
                    return MboxImportReport(batch: done, alreadyImported: true)
                }
            }
            let at = Int(now().timeIntervalSince1970)
            try db.execute(sql: """
                INSERT INTO import_batches (account_id, kind, file_path, file_size, file_modified_at, head_sha256, variant, started_at, updated_at)
                VALUES (?, 'mbox', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [account.rawValue, path, identity.size, identity.modifiedAt, identity.head, variant.rawValue, at, at])
            return MboxImportReport(batch: try Self.batches(db, sql: "id = ?", [db.lastInsertedRowID])[0])
        }
        if report.alreadyImported { return report }

        var batch = report.batch
        var reader = MboxReader(try MboxFile(url: url, offset: batch.committedOffset), variant: batch.variant,
                                offset: batch.committedOffset)
        var levelRaised = try Self.hasImportedMail(archive)
        let id = batch.id
        logger.info("import started", metadata: ["batch": "\(id)"])
        while let message = try autoreleasepool(invoking: { try reader.next() }) {
            batch.messagesRead += 1
            batch.committedOffset = message.endOffset
            batch.bytesRead = message.endOffset
            let failure: String? = switch message.problem {
            case .cutShort?: "cut_short"
            case .tooLarge?: "too_large"
            case nil: message.bytes.isEmpty ? "empty" : nil
            }
            if let failure {
                batch.failed += 1
                report.failures[failure, default: 0] += 1
                try archive.database.write { db in try Self.save(db, batch, failure: (message.offset, failure), now: now()) }
            } else {
                do {
                    let outcome = try importer.importFromFile(Self.fileMessage(message, account: account, batch: batch.id),
                                                              raiseReaderLevel: !levelRaised) { db, outcome in
                        var counted = batch
                        switch outcome {
                        case .imported, .storedUnread: counted.imported += 1
                        case .duplicate: counted.duplicates += 1
                        }
                        try Self.save(db, counted, failure: nil, now: now())
                    }
                    switch outcome {
                    case .imported:
                        batch.imported += 1
                        levelRaised = true
                    case .storedUnread:
                        batch.imported += 1
                        report.storedUnread += 1
                        levelRaised = true
                    case .duplicate(let reason):
                        batch.duplicates += 1
                        report.duplicates[reason, default: 0] += 1
                    }
                } catch ImportError.tooManyStuck {
                    // Stop here; the offset stays at the last committed message, so the next run reads this one again.
                    throw ImportError.tooManyStuck
                } catch {
                    batch.failed += 1
                    report.failures["not_stored", default: 0] += 1
                    let summary = "batch \(batch.id), offset \(message.offset)"
                    logger.error("message not stored", metadata: ["at": "\(summary)", "error": "\(Redact.scrub(String(describing: error)))"])
                    try archive.database.write { db in try Self.save(db, batch, failure: (message.offset, "not_stored"), now: now()) }
                }
            }
            if let progress, batch.messagesRead % progressEvery == 0 { progress(batch) }
            if let stopAfter, batch.messagesRead - (report.resumedFrom == nil ? 0 : report.batch.messagesRead) >= stopAfter {
                report.batch = batch
                return report
            }
        }
        let finished = now()
        try archive.database.write { db in
            try db.execute(sql: "UPDATE import_batches SET finished_at = ?, updated_at = ?, committed_offset = ?, bytes_read = ? WHERE id = ?",
                           arguments: [Int(finished.timeIntervalSince1970), Int(finished.timeIntervalSince1970),
                                       batch.committedOffset, batch.bytesRead, batch.id])
        }
        batch.finishedAt = Date(timeIntervalSince1970: finished.timeIntervalSince1970.rounded(.down))
        report.batch = batch
        archive.database.releaseMemory()
        let summary = "batch \(batch.id): \(batch.messagesRead) read, \(batch.imported) imported, \(batch.duplicates) duplicates, \(batch.failed) failed"
        logger.info("import finished", metadata: ["summary": "\(summary)"])
        return report
    }

    /// Unfinished imports, oldest first, for `stowmail status` (D-564).
    /// None on an archive that predates `v5` (a read-only open never migrates, D-605).
    public static func unfinished(_ db: Database, account: AccountID) throws -> [ImportBatch] {
        guard try ArchiveSchema.hasImportTables(db) else { return [] }
        return try batches(db, sql: "account_id = ? AND finished_at IS NULL", [account.rawValue])
    }

    /// Every batch of an account, oldest first.
    public static func batches(_ archive: Archive, account: AccountID) throws -> [ImportBatch] {
        try archive.database.read { db in
            guard try ArchiveSchema.hasImportTables(db) else { return [] }
            return try batches(db, sql: "account_id = ?", [account.rawValue])
        }
    }

    // MARK: - Messages

    /// The message with what Takeout's own headers say (D-566).
    static func fileMessage(_ message: MboxMessage, account: AccountID, batch: Int64) -> FileMessage {
        let takeout = TakeoutHeaders(message.bytes)
        return FileMessage(account: account, batch: batch, bytes: message.bytes, separatorDate: MboxSeparator.date(message.separator),
                           labels: takeout.labels, gmailThreadID: takeout.threadID, sourceState: takeout.sourceState)
    }

    // MARK: - Batches

    /// What identifies a file on resume (D-564).
    struct Identity {
        var size: Int64
        var modifiedAt: Int64
        var head: Data

        func matches(_ batch: ImportBatch) -> Bool { batch.fileSize == size && batch.storedHead == head && batch.storedModifiedAt == modifiedAt }
    }

    static func identity(of url: URL) throws -> Identity {
        let size = try MboxScan.checkFile(url)
        var status = stat()
        guard stat(url.path, &status) == 0 else { throw MboxFileError.unreadable(url.path) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: headBytes) ?? Data()
        return Identity(size: size, modifiedAt: Int64(status.st_mtimespec.tv_sec), head: Data(SHA256.hash(data: head)))
    }

    static func hasImportedMail(_ archive: Archive) throws -> Bool {
        try archive.database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE \(try ArchiveSchema.origin(db)) = 'imported')") ?? false
        }
    }

    static func save(_ db: Database, _ batch: ImportBatch, failure: (offset: Int64, reason: String)?, now: Date) throws {
        try db.execute(sql: """
            UPDATE import_batches SET committed_offset = ?, messages_read = ?, imported = ?, duplicates = ?, failed = ?,
                bytes_read = ?, updated_at = ? WHERE id = ?
            """, arguments: [batch.committedOffset, batch.messagesRead, batch.imported, batch.duplicates, batch.failed,
                             batch.bytesRead, Int(now.timeIntervalSince1970), batch.id])
        if let failure {
            try db.execute(sql: "INSERT INTO import_failures (batch_id, file_offset, reason) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                           arguments: [batch.id, failure.offset, failure.reason])
        }
    }

    static func batches(_ db: Database, sql condition: String, _ arguments: [any DatabaseValueConvertible]) throws -> [ImportBatch] {
        try Row.fetchAll(db, sql: "SELECT * FROM import_batches WHERE \(condition) ORDER BY id",
                         arguments: StatementArguments(arguments)).map { row in
            func date(_ column: String) -> Date? { (row[column] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
            var batch = ImportBatch(id: row["id"], account: AccountID(rawValue: row["account_id"]), filePath: row["file_path"],
                                    fileSize: row["file_size"], variant: MboxVariant(rawValue: row["variant"]) ?? .mboxrd,
                                    committedOffset: row["committed_offset"], startedAt: date("started_at")!, updatedAt: date("updated_at")!)
            batch.messagesRead = row["messages_read"]
            batch.imported = row["imported"]
            batch.duplicates = row["duplicates"]
            batch.failed = row["failed"]
            batch.bytesRead = row["bytes_read"]
            batch.finishedAt = date("finished_at")
            batch.storedHead = row["head_sha256"]
            batch.storedModifiedAt = row["file_modified_at"]
            return batch
        }
    }
}

extension ImportBatch {
    init(id: Int64, account: AccountID, filePath: String, fileSize: Int64, variant: MboxVariant, committedOffset: Int64,
         startedAt: Date, updatedAt: Date) {
        self.id = id
        self.account = account
        self.filePath = filePath
        self.fileSize = fileSize
        self.variant = variant
        self.committedOffset = committedOffset
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

/// What Google Takeout's own headers say about a message (D-566).
struct TakeoutHeaders: Equatable {
    var labels: [String] = []
    var threadID: UInt64?
    var sourceState: SourceState = .present

    /// Takeout's names for Gmail's system labels, as Gmail sync stores them from `X-GM-LABELS`.
    static let systemLabels = ["Inbox": "\\Inbox", "Sent": "\\Sent", "Important": "\\Important", "Starred": "\\Starred",
                               "Drafts": "\\Draft", "Draft": "\\Draft"]
    /// Takeout's markers that are not labels in Gmail's IMAP: read state, the archived marker and tabs.
    static func isMarker(_ name: String) -> Bool {
        ["Opened", "Unread", "Archived"].contains(name) || name.hasPrefix("Category ")
    }

    init(_ bytes: Data) {
        var warnings: [String] = []
        let fields = HeaderParser.splitFields(bytes, warnings: &warnings).fields
        if let thread = fields.first(where: { $0.name.caseInsensitiveCompare("X-GM-THRID") == .orderedSame }) {
            threadID = UInt64(thread.value.trimmingCharacters(in: .whitespaces))
        }
        guard let field = fields.first(where: { $0.name.caseInsensitiveCompare("X-Gmail-Labels") == .orderedSame }) else { return }
        for name in Self.split(field.value) {
            switch name {
            case "Spam": sourceState = .spam
            case "Trash" where sourceState != .spam: sourceState = .trashed
            case "Trash": break
            case _ where Self.isMarker(name): break
            default:
                let label = Self.systemLabels[name] ?? name
                if !labels.contains(label) { labels.append(label) }
            }
        }
    }

    /// Splits the comma-separated list, keeping commas inside double quotes, and decodes RFC 2047 words.
    static func split(_ value: String) -> [String] {
        var names: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            switch character {
            case "\"": quoted.toggle()
            case "," where !quoted:
                names.append(current)
                current = ""
            default: current.append(character)
            }
        }
        names.append(current)
        return names.map { EncodedWords.decode($0.trimmingCharacters(in: .whitespaces)).text }.filter { !$0.isEmpty }
    }
}
