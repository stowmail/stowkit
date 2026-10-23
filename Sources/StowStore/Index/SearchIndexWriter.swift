import Foundation
import GRDB

/// Keeps the full-text index (`messages_fts`, rowid = `messages.id`) in step
/// with the stored text it is built from: subject, addresses with display
/// names, body, attachment names and attachment text.
///
/// The index is an FTS5 *external content* table over the view
/// `messages_fts_content` (D-030): it holds the search index only, not a
/// second copy of the text. FTS5 cannot see changes to that text by itself,
/// and removing an entry needs exactly the text it was built from. So the rule
/// is: `remove` a message's entry before changing any of its text, and `index`
/// it again afterwards (`updating` does both). Import only ever adds.
///
/// Lives in `StowStore` because the importer indexes inline, in the same
/// transaction as the message, and the OCR runner re-indexes when new text
/// arrives. `StowSearch` only reads the index.
public enum SearchIndexWriter {
    static let columns = "subject, from_text, to_text, cc_text, body, attachment_names, attachment_text"

    /// Adds the index entry for a message from its stored text. Call inside a
    /// write transaction, once the message's rows are in place.
    public static func index(_ db: Database, messageID: Int64) throws {
        try db.execute(sql: """
            INSERT INTO messages_fts (rowid, \(columns))
            SELECT id, \(columns) FROM messages_fts_content WHERE id = ?
            """, arguments: [messageID])
    }

    /// Removes a message's index entry, using its current stored text. Call
    /// before that text changes or the message's rows are deleted.
    public static func remove(_ db: Database, messageID: Int64) throws {
        try db.execute(sql: """
            INSERT INTO messages_fts (messages_fts, rowid, \(columns))
            SELECT 'delete', id, \(columns) FROM messages_fts_content WHERE id = ?
            """, arguments: [messageID])
    }

    /// Runs `change`, which alters text the given messages are indexed from,
    /// with their entries removed before and added back after.
    public static func updating(_ db: Database, messageIDs: [Int64], change: () throws -> Void) throws {
        for id in messageIDs { try remove(db, messageID: id) }
        try change()
        for id in messageIDs { try index(db, messageID: id) }
    }

    /// The messages that contain an attachment, whose entries depend on its text.
    public static func messages(containing attachmentID: Int64, _ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT DISTINCT message_id FROM message_attachments WHERE attachment_id = ? ORDER BY message_id",
                           arguments: [attachmentID])
    }

    /// FTS5's own check that the index matches the stored text exactly. True when it does.
    public static func integrityCheck(_ db: Database) throws -> Bool {
        do {
            try db.execute(sql: "INSERT INTO messages_fts (messages_fts, rank) VALUES ('integrity-check', 1)")
            return true
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT {
            return false
        }
    }

    /// Rebuilds the whole index from the stored text. A repair tool, never needed in normal running.
    public static func rebuild(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO messages_fts (messages_fts) VALUES ('rebuild')")
    }
}
