import Foundation
import GRDB
import StowCore

/// Counts and sizes for `stowmail stats`. Numbers only, never content.
public struct ArchiveStats: Sendable, Equatable {
    public var accounts = 0
    public var messages = 0
    public var degradedMessages = 0
    public var failedMessages = 0
    /// Messages stored as skeletons (attachments cut out) and stored whole (D-029).
    public var skeletonMessages = 0
    public var wholeMessages = 0
    /// Attachment bodies left inside message files because they would not rebuild exactly.
    public var attachmentsKeptInline = 0
    /// What the provider reports (RFC822.SIZE, an estimate on Exchange), and
    /// what the message files take on disk compressed and encrypted.
    public var rawBytes = 0
    public var rawStoredBytes = 0
    /// Attachment references across messages, and distinct attachment files.
    public var attachmentReferences = 0
    public var distinctAttachments = 0
    /// Decoded bytes if every reference were stored separately, versus actually stored once.
    public var attachmentBytesReferenced = 0
    public var attachmentBytesDistinct = 0
    public var attachmentStoredBytes = 0
    public var ocrPending = 0
    public var databaseBytes = 0

    public var dedupSavedBytes: Int { attachmentBytesReferenced - attachmentBytesDistinct }
    /// Message files, attachment files and the database together.
    public var totalStoredBytes: Int { rawStoredBytes + attachmentStoredBytes + databaseBytes }
    /// The archive's size as a share of what the provider reports for the same mail.
    public var storedRatio: Double { rawBytes > 0 ? Double(totalStoredBytes) / Double(rawBytes) : 0 }

    /// Totals for the whole archive, or for one account. The database cannot
    /// be split by account, so its size is always the whole file.
    public static func collect(_ archive: Archive, account: AccountID? = nil) throws -> ArchiveStats {
        var stats = try archive.database.read { db -> ArchiveStats in
            var stats = ArchiveStats()
            let scope = account == nil ? "1" : "m.account_id = ?"
            let arguments: StatementArguments = account.map { [$0.rawValue] } ?? []
            func int(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
            stats.accounts = account == nil ? try Int.fetchOne(db, sql: "SELECT count(*) FROM accounts") ?? 0 : 1
            stats.messages = try int("SELECT count(*) FROM messages m WHERE \(scope)")
            stats.degradedMessages = try int("SELECT count(*) FROM messages m WHERE \(scope) AND parse_status = 'degraded'")
            stats.failedMessages = try int("SELECT count(*) FROM messages m WHERE \(scope) AND parse_status = 'failed'")
            stats.skeletonMessages = try int("SELECT count(*) FROM messages m WHERE \(scope) AND raw_state = 'skeleton'")
            stats.wholeMessages = stats.messages - stats.skeletonMessages
            stats.attachmentsKeptInline = try int("SELECT coalesce(sum(raw_inline_attachments), 0) FROM messages m WHERE \(scope)")
            stats.rawBytes = try int("SELECT coalesce(sum(size), 0) FROM messages m WHERE \(scope)")
            // Identical messages in two accounts share one file: count each file once.
            stats.rawStoredBytes = try int("""
                SELECT coalesce(sum(s), 0) FROM (SELECT max(raw_stored_size) AS s FROM messages m WHERE \(scope) GROUP BY raw_hash)
                """)
            stats.attachmentReferences = try int("SELECT count(*) FROM message_attachments ma JOIN messages m ON m.id = ma.message_id WHERE \(scope)")
            let used = "SELECT DISTINCT ma.attachment_id FROM message_attachments ma JOIN messages m ON m.id = ma.message_id WHERE \(scope)"
            stats.distinctAttachments = try int("SELECT count(*) FROM (\(used))")
            stats.attachmentBytesReferenced = try int("""
                SELECT coalesce(sum(a.size), 0) FROM message_attachments ma JOIN attachments a ON a.id = ma.attachment_id
                JOIN messages m ON m.id = ma.message_id WHERE \(scope)
                """)
            stats.attachmentBytesDistinct = try int("SELECT coalesce(sum(size), 0) FROM attachments WHERE id IN (\(used))")
            stats.attachmentStoredBytes = try int("SELECT coalesce(sum(stored_size), 0) FROM attachments WHERE id IN (\(used))")
            stats.ocrPending = try int("SELECT count(*) FROM attachments WHERE text_status = 'ocr_pending' AND id IN (\(used))")
            return stats
        }
        for suffix in ["", "-wal"] {
            stats.databaseBytes += EncryptedFileStore.fileSize(URL(fileURLWithPath: archive.location.databaseURL.path + suffix)) ?? 0
        }
        return stats
    }
}
