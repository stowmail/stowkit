import Foundation
import GRDB

/// Emails Stow could not read in full (D-481), for `stowmail status`,
/// `doctor`, `stats` and `verify`. Counts only, never content.
public struct UnreadText: Sendable, Equatable {
    /// Messages whose own text was not read: stored whole and unread (D-502).
    public var messages = 0
    /// Messages with at least one attachment whose text could not be read.
    public var messagesWithUnreadAttachments = 0
    /// Either kind, each message once.
    public var total = 0

    public init(messages: Int = 0, messagesWithUnreadAttachments: Int = 0, total: Int = 0) {
        self.messages = messages
        self.messagesWithUnreadAttachments = messagesWithUnreadAttachments
        self.total = total
    }

    /// The counts, or nil for an archive not yet upgraded to v2 (a read-only
    /// open does not migrate), which has no marks to count. Each query reads
    /// only a partial index (D-501).
    public static func collect(_ db: Database) throws -> UnreadText? {
        guard try hasMarks(db) else { return nil }
        let unreadAttachments = """
            SELECT message_id FROM message_attachments
            WHERE attachment_id IN (SELECT id FROM attachments WHERE text_failed_version IS NOT NULL)
            """
        return UnreadText(
            messages: try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE text_state = 'incomplete'") ?? 0,
            messagesWithUnreadAttachments: try Int.fetchOne(db, sql: "SELECT count(DISTINCT message_id) FROM (\(unreadAttachments))") ?? 0,
            total: try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (SELECT id FROM messages WHERE text_state = 'incomplete' UNION \(unreadAttachments))
                """) ?? 0)
    }

    public static func collect(_ archive: Archive) throws -> UnreadText? {
        try archive.database.read { db in try collect(db) }
    }

    /// Whether the archive has v2's columns for the mark (D-501). False for an
    /// archive a v1 build made and only read-only opens have seen since.
    public static func hasMarks(_ db: Database) throws -> Bool {
        try db.columns(in: "messages").contains { $0.name == "text_state" }
    }

    /// One line for people: what is missing, and that nothing is lost.
    public var summary: String {
        let emails = total == 1 ? "1 email" : "\(total) emails"
        var parts: [String] = []
        if messages > 0 { parts.append("\(messages) whose text could not be read") }
        if messagesWithUnreadAttachments > 0 { parts.append("\(messagesWithUnreadAttachments) with an attachment whose text could not be read") }
        return "\(emails) Stow could not read in full (\(parts.joined(separator: ", "))). Each is stored whole and opens and exports as usual; "
            + "search misses the part that was not read. Stow tries again after an update."
    }
}
