import Foundation
import GRDB

/// Counts and sizes for `stowmail stats`. Numbers only, never content.
public struct ArchiveStats: Sendable, Equatable {
    public var accounts = 0
    public var messages = 0
    public var degradedMessages = 0
    public var failedMessages = 0
    /// Original raw message bytes (RFC822.SIZE), and what they take on disk compressed and encrypted.
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

    public static func collect(_ archive: Archive) throws -> ArchiveStats {
        var stats = try archive.database.read { db -> ArchiveStats in
            var stats = ArchiveStats()
            func int(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
            stats.accounts = try int("SELECT count(*) FROM accounts")
            stats.messages = try int("SELECT count(*) FROM messages")
            stats.degradedMessages = try int("SELECT count(*) FROM messages WHERE parse_status = 'degraded'")
            stats.failedMessages = try int("SELECT count(*) FROM messages WHERE parse_status = 'failed'")
            stats.rawBytes = try int("SELECT coalesce(sum(size), 0) FROM messages")
            stats.rawStoredBytes = try int("SELECT coalesce(sum(raw_stored_size), 0) FROM messages")
            stats.attachmentReferences = try int("SELECT count(*) FROM message_attachments")
            stats.distinctAttachments = try int("SELECT count(*) FROM attachments")
            stats.attachmentBytesReferenced = try int("""
                SELECT coalesce(sum(a.size), 0) FROM message_attachments ma JOIN attachments a ON a.id = ma.attachment_id
                """)
            stats.attachmentBytesDistinct = try int("SELECT coalesce(sum(size), 0) FROM attachments")
            stats.attachmentStoredBytes = try int("SELECT coalesce(sum(stored_size), 0) FROM attachments")
            stats.ocrPending = try int("SELECT count(*) FROM attachments WHERE text_status = 'ocr_pending'")
            return stats
        }
        for suffix in ["", "-wal"] {
            stats.databaseBytes += EncryptedFileStore.fileSize(URL(fileURLWithPath: archive.location.databaseURL.path + suffix)) ?? 0
        }
        return stats
    }
}
