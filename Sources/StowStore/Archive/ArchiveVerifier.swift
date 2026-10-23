import Foundation
import GRDB
import StowCore

/// What `stowmail verify` found in the archive. IDs and counts only, never content.
public struct ArchiveVerifyReport: Sendable, Equatable {
    public var messages = 0
    /// Rebuilt from their files and identical to what was downloaded.
    public var rebuilt = 0
    /// Messages that did not rebuild, or whose file is missing or damaged.
    public var failedMessages: [StoredMessageID] = []
    public var attachments = 0
    /// Attachment files missing, damaged, or not matching their recorded hash.
    public var failedAttachments: [Int64] = []
    /// Files no database row refers to: left by an interrupted removal, harmless.
    public var unusedMessageFiles = 0
    public var unusedAttachmentFiles = 0
    /// Whether the full-text index matches the stored text (FTS5 integrity-check).
    public var searchIndexConsistent = true
    /// SQLite's own check of the database file.
    public var databaseIntegrity = "ok"
    public var foreignKeyProblems = 0

    public var isClean: Bool {
        failedMessages.isEmpty && failedAttachments.isEmpty && searchIndexConsistent
            && databaseIntegrity == "ok" && foreignKeyProblems == 0
    }
}

/// Checks the whole archive without changing it (D-042): every message
/// rebuilds byte for byte (its keyed hash matches the one recorded when it was
/// downloaded), every attachment file opens and matches its hash, the search
/// index matches the text, and the database passes SQLite's integrity check.
/// Also run on the copy before an archive move switches over (D-035).
public struct ArchiveVerifier: Sendable {
    public let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    /// - Parameter progress: called with (messages checked, total) every 500 messages.
    public func run(progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ArchiveVerifyReport {
        var report = ArchiveVerifyReport()
        let messages = try archive.database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, raw_hash, raw_state FROM messages ORDER BY id")
        }
        report.messages = messages.count
        for (index, row) in messages.enumerated() {
            let id: Int64 = row["id"]
            let hash: Data = row["raw_hash"]
            let state: String = row["raw_state"]
            if checkMessage(hash: hash, state: state) { report.rebuilt += 1 } else { report.failedMessages.append(id) }
            if let progress, (index + 1) % 500 == 0 { progress(index + 1, messages.count) }
        }

        let attachments = try archive.database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, content_hash, size FROM attachments ORDER BY id")
        }
        report.attachments = attachments.count
        for row in attachments {
            let hash: Data = row["content_hash"]
            let size: Int = row["size"]
            let ok = autoreleasepool { () -> Bool in
                guard let content = try? archive.attachmentFiles.read(hash) else { return false }
                return content.count == size && archive.attachmentFiles.hash(of: content) == hash
            }
            if !ok { report.failedAttachments.append(row["id"]) }
        }

        let (rawHashes, attachmentHashes) = try archive.database.read { db in
            (Set(try Data.fetchAll(db, sql: "SELECT DISTINCT raw_hash FROM messages")),
             Set(try Data.fetchAll(db, sql: "SELECT content_hash FROM attachments")))
        }
        report.unusedMessageFiles = archive.rawFiles.allHashes().filter { !rawHashes.contains($0) }.count
        report.unusedAttachmentFiles = archive.attachmentFiles.allHashes().filter { !attachmentHashes.contains($0) }.count

        try archive.database.writeWithoutTransaction { db in
            report.searchIndexConsistent = try SearchIndexWriter.integrityCheck(db)
            report.databaseIntegrity = try String.fetchAll(db, sql: "PRAGMA integrity_check").joined(separator: "; ")
            report.foreignKeyProblems = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        }
        return report
    }

    /// Rebuilds one message and compares its keyed hash with the recorded one.
    /// The file's skeleton flag must agree with the database too.
    func checkMessage(hash: Data, state: String) -> Bool {
        autoreleasepool {
            guard let file = try? archive.rawFiles.readFile(hash), file.isSkeleton == (state == "skeleton") else { return false }
            let rebuilt = state == "skeleton" ? try? RawCompaction.expand(file.content, attachments: archive.attachmentFiles) : file.content
            guard let rebuilt else { return false }
            return archive.rawFiles.hash(of: rebuilt) == hash
        }
    }
}
