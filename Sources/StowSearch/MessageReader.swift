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
/// Made from an `Archive`, it also reads inline parts by Content-ID (R8),
/// attachment bytes (D-410) and the displayable body (R9): the calls that open
/// encrypted files, decrypting them in memory.
public final class MessageReader: MessageReading, InlinePartReading, MessageBodyReading, AttachmentDataReading, Sendable {
    let database: any DatabaseReader
    /// Nil when made from a database alone (the MCP server, D-081): no file key.
    let archive: Archive?

    public init(database: any DatabaseReader) {
        self.database = database
        archive = nil
    }

    public init(archive: Archive) {
        database = archive.database
        self.archive = archive
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
            SELECT m.account_id, m.thread_key, m.internal_date, m.sent_date, m.subject, m.source_state, m.imported_at, m.source_state_at,
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
            attachments: try attachments(db, message: id),
            places: try places(db, message: id),
            importedAt: Date(timeIntervalSince1970: TimeInterval(row["imported_at"] as Int64)),
            sourceStateAt: (row["source_state_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    /// Where the provider has the message now (R11): every folder or label holding a copy the
    /// server has not dropped, in name order. A Gmail label counts only while the message still
    /// has a folder copy (All Mail), so a deleted message never shows the labels it had.
    func places(_ db: Database, message: StoredMessageID) throws -> [ArchiveFolder] {
        try Row.fetchAll(db, sql: """
            SELECT f.id, f.account_id, f.name, f.kind, f.special_use, f.delimiter FROM message_folders mf
            JOIN folders f ON f.id = mf.folder_id
            WHERE mf.message_id = ? AND mf.removed_from_server_at IS NULL
                AND (f.kind = 'folder' OR EXISTS (SELECT 1 FROM message_folders c JOIN folders cf ON cf.id = c.folder_id
                    WHERE c.message_id = mf.message_id AND cf.kind = 'folder' AND c.removed_from_server_at IS NULL))
            ORDER BY f.kind, f.name
            """, arguments: [message]).map { row in
            ArchiveFolder(id: row["id"], accountID: AccountID(rawValue: row["account_id"]), name: row["name"],
                          kind: ArchiveFolder.Kind(rawValue: row["kind"]) ?? .folder,
                          specialUse: row["special_use"], delimiter: row["delimiter"])
        }
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
        guard let attachmentFiles = archive?.attachmentFiles else { throw MessageReaderError.noFileKey }
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

    public func attachmentData(message: StoredMessageID, index: Int) async throws -> AttachmentData? {
        guard let attachmentFiles = archive?.attachmentFiles else { throw MessageReaderError.noFileKey }
        guard index >= 1 else { return nil }
        let found = try await database.read { db -> (hash: Data, info: AttachmentInfo)? in
            let rows = try Row.fetchAll(db, sql: Self.attachmentSQL, arguments: [message])
            guard index <= rows.count else { return nil }
            return (rows[index - 1]["content_hash"], Self.info(rows[index - 1], index: index))
        }
        guard let found else { return nil }
        // Decrypted into memory only; nothing is written to disk.
        return AttachmentData(messageID: message, info: found.info, data: try attachmentFiles.read(found.hash))
    }

    public func body(of message: StoredMessageID) async throws -> MessageBody? {
        guard let archive else { throw MessageReaderError.noFileKey }
        // Decrypted and parsed in memory only; nothing is written to disk (R9, D-409).
        guard let raw = try archive.rawMessage(message) else { return nil }
        let parts = MIMEParser().displayBody(raw)
        return MessageBody(messageID: message, html: parts.html, plain: parts.plain,
                           contentIDs: parts.html.map(MessageBody.contentIDs(inHTML:)) ?? [])
    }

    static let attachmentSQL = """
        SELECT x.attachment_id, t.content_hash, x.filename, coalesce(t.mime_type, x.declared_mime_type) AS mime_type, x.disposition,
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
        case .noFileKey: "This reader was opened without the archive's file key, so it cannot read attachments or rebuild a message's body."
        }
    }
}
