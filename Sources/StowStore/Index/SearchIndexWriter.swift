import Foundation
import GRDB

/// Writes the full-text index row for a message (`messages_fts`, rowid =
/// `messages.id`), built from what is already stored: subject, addresses with
/// display names, body, attachment names and attachment text.
///
/// Lives in `StowStore` because the importer indexes inline, in the same
/// transaction as the message, and the OCR runner re-indexes when new text
/// arrives. `StowSearch` only reads the index.
public enum SearchIndexWriter {
    /// (Re)builds the index row for one message. Call inside a write transaction.
    public static func index(_ db: Database, messageID: Int64) throws {
        guard let subject = try Row.fetchOne(db, sql: "SELECT subject FROM messages WHERE id = ?", arguments: [messageID])
        else { return }

        func addresses(_ roles: [String]) throws -> String {
            let rows = try Row.fetchAll(db, sql: """
                SELECT ma.display_name, a.address FROM message_addresses ma JOIN addresses a ON a.id = ma.address_id
                WHERE ma.message_id = ? AND ma.role IN (\(roles.map { "'\($0)'" }.joined(separator: ",")))
                ORDER BY ma.role, ma.position
                """, arguments: [messageID])
            return rows.map { row in
                [row["display_name"] as String?, row["address"] as String?].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: ", ")
        }

        let body = try String.fetchOne(db, sql: """
            SELECT coalesce(text_plain, text_from_html) FROM message_bodies WHERE message_id = ?
            """, arguments: [messageID])
        let names = try String.fetchAll(db, sql: """
            SELECT filename FROM message_attachments WHERE message_id = ? AND filename IS NOT NULL ORDER BY part_path
            """, arguments: [messageID])
        let texts = try String.fetchAll(db, sql: """
            SELECT DISTINCT t.text FROM message_attachments ma JOIN attachment_text t ON t.attachment_id = ma.attachment_id
            WHERE ma.message_id = ? ORDER BY ma.part_path
            """, arguments: [messageID])

        try db.execute(sql: "DELETE FROM messages_fts WHERE rowid = ?", arguments: [messageID])
        try db.execute(sql: """
            INSERT INTO messages_fts (rowid, subject, from_text, to_text, cc_text, body, attachment_names, attachment_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                messageID, subject["subject"] as String?, try addresses(["from", "sender", "reply_to"]),
                try addresses(["to"]), try addresses(["cc", "bcc"]), body,
                names.joined(separator: "\n"), texts.joined(separator: "\n\n"),
            ])
    }

    /// Re-indexes every message that contains the given attachment, after its text changed (OCR).
    public static func reindex(_ db: Database, attachmentID: Int64) throws {
        let messages = try Int64.fetchAll(db, sql: "SELECT DISTINCT message_id FROM message_attachments WHERE attachment_id = ?",
                                          arguments: [attachmentID])
        for message in messages { try index(db, messageID: message) }
    }
}
