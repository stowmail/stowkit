import Foundation
import GRDB
import StowCore
import StowStore

/// The read path: a stored message's headers, body text and attachment list,
/// and an attachment's extracted text (D-081). Reads only the database: the
/// body and attachment text were extracted at import, so no encrypted file is
/// opened and the file key is not needed.
///
/// Long text is cut in SQL (`substr`), so a 5 MB body never leaves SQLite whole.
///
/// Made from an `Archive`, it also reads inline parts by Content-ID (R8): the
/// one call that opens an encrypted attachment file, decrypting it in memory.
public final class MessageReader: MessageReading, InlinePartReading, Sendable {
    let database: any DatabaseReader
    /// Nil when made from a database alone (the MCP server, D-081): no file key.
    let attachmentFiles: EncryptedFileStore?

    public init(database: any DatabaseReader) {
        self.database = database
        attachmentFiles = nil
    }

    public init(archive: Archive) {
        database = archive.database
        attachmentFiles = archive.attachmentFiles
    }

    public func message(_ id: StoredMessageID, bodyLimit: Int) async throws -> MessageDetail? {
        try await database.read { db in try self.message(db, id, bodyLimit: bodyLimit) }
    }

    public func attachmentText(message: StoredMessageID, index: Int, offset: Int, limit: Int) async throws -> AttachmentText? {
        try await database.read { db in try self.attachmentText(db, message: message, index: index, offset: offset, limit: limit) }
    }

    func message(_ db: Database, _ id: StoredMessageID, bodyLimit: Int) throws -> MessageDetail? {
        let limit = max(0, bodyLimit)
        guard let row = try Row.fetchOne(db, sql: """
            SELECT m.account_id, m.thread_key, m.internal_date, m.sent_date, m.subject, m.source_state,
                   b.text_plain IS NULL AND b.text_from_html IS NOT NULL AS from_html,
                   substr(coalesce(b.text_plain, b.text_from_html), 1, ?) AS body,
                   length(coalesce(b.text_plain, b.text_from_html)) AS body_length
            FROM messages m LEFT JOIN message_bodies b ON b.message_id = m.id
            WHERE m.id = ?
            """, arguments: [limit, id]) else { return nil }

        var addresses: [String: [EmailAddress]] = [:]
        for address in try Row.fetchAll(db, sql: """
            SELECT ma.role, ma.display_name, a.address FROM message_addresses ma JOIN addresses a ON a.id = ma.address_id
            WHERE ma.message_id = ? AND ma.role IN ('from', 'to', 'cc') ORDER BY ma.role, ma.position
            """, arguments: [id]) {
            addresses[address["role"], default: []].append(EmailAddress(name: address["display_name"], address: address["address"]))
        }

        let bodyLength: Int = row["body_length"] ?? 0
        let body: String? = row["body"]
        return MessageDetail(
            messageID: id,
            accountID: AccountID(rawValue: row["account_id"]),
            threadKey: row["thread_key"],
            date: Date(timeIntervalSince1970: TimeInterval(row["internal_date"] as Int64)),
            sentDate: (row["sent_date"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            from: addresses["from"]?.first,
            to: addresses["to"] ?? [],
            cc: addresses["cc"] ?? [],
            subject: row["subject"],
            sourceState: SourceState(rawValue: row["source_state"]) ?? .present,
            body: body,
            bodyFromHTML: row["from_html"] ?? false,
            bodyLength: bodyLength,
            bodyTruncated: bodyLength > limit,
            attachments: try attachments(db, message: id))
    }

    /// The message's attachments in MIME part order, numbered from 1.
    func attachments(_ db: Database, message: StoredMessageID) throws -> [AttachmentInfo] {
        try Row.fetchAll(db, sql: Self.attachmentSQL, arguments: [message]).enumerated().map { position, row in
            Self.info(row, index: position + 1)
        }
    }

    func attachmentText(_ db: Database, message: StoredMessageID, index: Int, offset: Int, limit: Int) throws -> AttachmentText? {
        guard index >= 1,
              let account = try String.fetchOne(db, sql: "SELECT account_id FROM messages WHERE id = ?", arguments: [message])
        else { return nil }
        let rows = try Row.fetchAll(db, sql: Self.attachmentSQL, arguments: [message])
        guard index <= rows.count else { return nil }
        let row = rows[index - 1]
        let start = min(max(0, offset), Int(Int32.max))  // no overflow in `start + 1`, whatever the caller passes
        let text = try Row.fetchOne(db, sql: "SELECT method, substr(text, ?, ?) AS text FROM attachment_text WHERE attachment_id = ?",
                                    arguments: [start + 1, max(0, limit), row["attachment_id"] as Int64])
        return AttachmentText(messageID: message, accountID: AccountID(rawValue: account), info: Self.info(row, index: index),
                              method: text?["method"], text: text?["text"], offset: start)
    }

    public func inlinePart(message: StoredMessageID, contentID: String) async throws -> InlinePart? {
        guard let attachmentFiles else { throw MessageReaderError.noFileKey }
        let wanted = InlinePart.contentID(fromReference: contentID)
        guard !wanted.isEmpty else { return nil }
        // An exact match first; Content-IDs are compared without case only when nothing matches exactly.
        let found = try await database.read { db -> (hash: Data, part: InlinePart)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT x.content_id, x.filename, x.declared_mime_type, t.mime_type, t.content_hash
                FROM message_attachments x JOIN attachments t ON t.id = x.attachment_id
                WHERE x.message_id = ? AND x.content_id = ? COLLATE NOCASE
                ORDER BY x.content_id = ? DESC, x.part_path LIMIT 1
                """, arguments: [message, wanted, wanted]) else { return nil }
            return (row["content_hash"], InlinePart(messageID: message, contentID: row["content_id"], data: Data(),
                                                    declaredType: row["declared_mime_type"], detectedType: row["mime_type"],
                                                    filename: row["filename"]))
        }
        guard let found else { return nil }
        var part = found.part
        // Decrypted into memory only; nothing is written to disk.
        part.data = try attachmentFiles.read(found.hash)
        return part
    }

    static let attachmentSQL = """
        SELECT x.attachment_id, x.filename, coalesce(t.mime_type, x.declared_mime_type) AS mime_type, x.disposition,
               t.size, t.text_status, coalesce((SELECT length(at.text) FROM attachment_text at WHERE at.attachment_id = t.id), 0) AS text_length
        FROM message_attachments x JOIN attachments t ON t.id = x.attachment_id
        WHERE x.message_id = ? ORDER BY x.part_path
        """

    static func info(_ row: Row, index: Int) -> AttachmentInfo {
        AttachmentInfo(index: index, filename: row["filename"], mimeType: row["mime_type"], size: row["size"],
                       disposition: row["disposition"], textStatus: row["text_status"], textLength: row["text_length"])
    }
}

public enum MessageReaderError: Error, Equatable, CustomStringConvertible {
    case noFileKey

    public var description: String {
        switch self {
        case .noFileKey: "This reader was opened without the archive's file key, so it cannot read attachments."
        }
    }
}
