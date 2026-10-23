import Foundation
import GRDB
import Logging
import StowCore

public enum ImportError: Error, Equatable, CustomStringConvertible {
    /// The message belongs to an account the archive does not know. Register it first.
    case unknownAccount(AccountID)

    public var description: String {
        switch self {
        case .unknownAccount(let id): "Account \(id) is not in the archive; register it before importing"
        }
    }
}

/// What happened to one message.
public enum ImportOutcome: Equatable, Sendable {
    /// New message stored.
    case imported(StoredMessageID)
    /// The same bytes were already stored for this account; only the new folder or label was linked.
    case linked(StoredMessageID)
    /// This exact server copy (account, folder, UIDVALIDITY, UID) was imported before. Nothing changed.
    case alreadyPresent
}

/// Totals for an import run. Counts and sizes only, never content.
public struct ImportSummary: Sendable, Equatable, CustomStringConvertible {
    public var imported = 0
    public var linked = 0
    public var alreadyPresent = 0
    public var failed = 0
    public var bytes = 0
    public var seconds: Double = 0

    public init() {}

    public var messagesPerSecond: Double { seconds > 0 ? Double(imported + linked) / seconds : 0 }

    public var description: String {
        String(format: "%d imported, %d linked, %d already present, %d failed, %.1f MB in %.1f s (%.0f messages/s)",
               imported, linked, alreadyPresent, failed, Double(bytes) / 1_048_576, seconds, messagesPerSecond)
    }
}

/// Turns raw messages into archive rows and encrypted files (brief step 2).
///
/// Each message is written in one database transaction, after its encrypted
/// files are in place, so a crash leaves either the whole message or none of
/// its rows (an orphaned encrypted file is harmless and reused next time).
/// Importing is idempotent: the same server copy is skipped before it is even
/// read, and the same bytes for the same account map to the same row
/// (`UNIQUE (account_id, raw_hash)`).
public final class Importer: Sendable {
    public let archive: Archive
    let parser = MIMEParser()
    let extractor = TextExtractor()
    /// False only for measuring import speed without inline extraction (QA checklist).
    let extractText: Bool
    let logger = Logger(label: "uk.getstow.store.import")

    public init(archive: Archive, extractText: Bool = true) {
        self.archive = archive
        self.extractText = extractText
    }

    // MARK: - Bulk

    /// Imports every message the source lists. Failures are counted and
    /// logged (by key, never content) and do not stop the run.
    public func importAll(
        from source: some RawMessageSource,
        progress: (@Sendable (ImportSummary) -> Void)? = nil
    ) async throws -> ImportSummary {
        let start = Date()
        var summary = ImportSummary()
        let keys = try await source.listKeys()
        for (index, key) in keys.enumerated() {
            do {
                if try isAlreadyPresent(key) {
                    summary.alreadyPresent += 1
                } else {
                    let raw = try await source.read(key)
                    switch try importMessage(raw) {
                    case .imported: summary.imported += 1
                    case .linked: summary.linked += 1
                    case .alreadyPresent: summary.alreadyPresent += 1
                    }
                    summary.bytes += raw.bytes.count
                }
            } catch {
                summary.failed += 1
                logger.error("import failed", metadata: ["key": "\(key)", "error": "\(Redact.scrub(String(describing: error)))"])
            }
            if let progress, (index + 1) % 1000 == 0 {
                summary.seconds = Date().timeIntervalSince(start)
                progress(summary)
            }
        }
        summary.seconds = Date().timeIntervalSince(start)
        logger.info("import finished", metadata: ["summary": "\(summary)"])
        return summary
    }

    // MARK: - One message

    public func isAlreadyPresent(_ key: RawMessageKey) throws -> Bool {
        try archive.database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                    WHERE f.account_id = ? AND f.kind = 'folder' AND f.name = ? AND mf.uid_validity = ? AND mf.uid = ?)
                """, arguments: [key.accountID.rawValue, key.folder, Int64(key.uidValidity), Int64(key.uid)]) ?? false
        }
    }

    public func importMessage(_ raw: RawMessage) throws -> ImportOutcome {
        let key = raw.key
        guard try archive.accountExists(key.accountID) else { throw ImportError.unknownAccount(key.accountID) }
        if try isAlreadyPresent(key) { return .alreadyPresent }

        let rawHash = archive.rawFiles.hash(of: raw.bytes)
        if let existing = try existingMessage(account: key.accountID, rawHash: rawHash) {
            try archive.database.write { db in try link(db, messageID: existing, raw: raw) }
            return .linked(existing)
        }

        // Work outside the transaction: parse, encrypt and write files, extract text.
        let parsed = parser.parse(raw.bytes)
        let rawStored = try archive.rawFiles.write(raw.bytes, hash: rawHash).storedSize
        let attachments = try parsed.attachments.map(prepare)

        return try archive.database.write { db -> ImportOutcome in
            // Another importer may have stored the same bytes meanwhile.
            if let existing = try Self.messageID(db, account: key.accountID, rawHash: rawHash) {
                try link(db, messageID: existing, raw: raw)
                return .linked(existing)
            }
            let id = try insertMessage(db, raw: raw, rawHash: rawHash, rawStored: rawStored, parsed: parsed,
                                       hasAttachments: attachments.contains { $0.parsed.disposition == .attachment })
            try insertAddresses(db, messageID: id, headers: parsed.headers)
            try insertAttachments(db, messageID: id, attachments: attachments)
            try link(db, messageID: id, raw: raw)
            try SearchIndexWriter.index(db, messageID: id)
            return .imported(id)
        }
    }

    private func existingMessage(account: AccountID, rawHash: Data) throws -> StoredMessageID? {
        try archive.database.read { db in try Self.messageID(db, account: account, rawHash: rawHash) }
    }

    static func messageID(_ db: Database, account: AccountID, rawHash: Data) throws -> StoredMessageID? {
        try StoredMessageID.fetchOne(db, sql: "SELECT id FROM messages WHERE account_id = ? AND raw_hash = ?",
                                     arguments: [account.rawValue, rawHash])
    }

    // MARK: - Attachments

    struct PreparedAttachment {
        var parsed: ParsedAttachment
        var hash: Data
        var storedSize: Int
        /// Nil when the content was already in the archive: its text is there too.
        var extraction: ExtractionResult?
    }

    private func prepare(_ attachment: ParsedAttachment) throws -> PreparedAttachment {
        let hash = archive.attachmentFiles.hash(of: attachment.data)
        let known = try archive.database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM attachments WHERE content_hash = ?)", arguments: [hash]) ?? false
        }
        let stored = try archive.attachmentFiles.write(attachment.data, hash: hash).storedSize
        var extraction: ExtractionResult?
        if !known {
            extraction = extractText ? extractor.extract(attachment) : ExtractionResult.none
        }
        return PreparedAttachment(parsed: attachment, hash: hash, storedSize: stored, extraction: extraction)
    }

    private func insertAttachments(_ db: Database, messageID: StoredMessageID, attachments: [PreparedAttachment]) throws {
        let now = Int(Date().timeIntervalSince1970)
        for attachment in attachments {
            let extraction = attachment.extraction ?? .none
            // Insert, or find the existing row for this content (deduplication).
            let attachmentID = try Int64.fetchOne(db, sql: """
                INSERT INTO attachments (content_hash, size, stored_size, mime_type, text_status, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (content_hash) DO UPDATE SET content_hash = excluded.content_hash
                RETURNING id
                """, arguments: [attachment.hash, attachment.parsed.data.count, attachment.storedSize,
                                 TextExtractor.effectiveType(attachment.parsed), extraction.status.rawValue, now])!
            if let text = extraction.text, let method = extraction.method {
                try db.execute(sql: """
                    INSERT INTO attachment_text (attachment_id, text, method, extractor_version, extracted_at)
                    VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                    """, arguments: [attachmentID, text, method.rawValue, TextExtractor.version, now])
            }
            let parsed = attachment.parsed
            try db.execute(sql: """
                INSERT INTO message_attachments
                    (message_id, part_path, attachment_id, filename, declared_mime_type, disposition, content_id)
                VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [messageID, parsed.partPath, attachmentID, parsed.filename, parsed.declaredMimeType,
                                 parsed.disposition.rawValue, parsed.contentID])
        }
    }

    // MARK: - Rows

    private func insertMessage(
        _ db: Database, raw: RawMessage, rawHash: Data, rawStored: Int, parsed: ParsedMessage, hasAttachments: Bool
    ) throws -> StoredMessageID {
        let headers = parsed.headers
        let fromID = try headers.from.first.flatMap { try Self.addressID(db, $0) }
        let warnings = parsed.warnings.isEmpty ? nil
            : String(decoding: try JSONEncoder().encode(parsed.warnings), as: UTF8.self)
        let now = Int(Date().timeIntervalSince1970)
        try db.execute(sql: """
            INSERT INTO messages (
                account_id, raw_hash, rfc822_message_id, gmail_msgid, gmail_thrid, thread_key,
                internal_date, sent_date, date_raw, subject, from_address_id, size, has_attachments,
                raw_stored_size, parse_status, parse_warnings, parser_version, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                raw.key.accountID.rawValue, rawHash, headers.messageID,
                raw.gmailMessageID.map { Int64(bitPattern: $0) }, raw.gmailThreadID.map { Int64(bitPattern: $0) },
                Self.threadKey(raw: raw, headers: headers, rawHash: rawHash),
                Int(raw.internalDate.timeIntervalSince1970), headers.date.map { Int($0.timeIntervalSince1970) },
                headers.dateRaw, headers.subject, fromID, raw.size > 0 ? raw.size : raw.bytes.count, hasAttachments,
                rawStored, parsed.status.rawValue, warnings, MIMEParser.version, now,
            ])
        let id = db.lastInsertedRowID
        if parsed.textPlain != nil || parsed.textFromHTML != nil {
            // The HTML text is only kept when there is no plain part (it is usually the same words).
            try db.execute(sql: "INSERT INTO message_bodies (message_id, text_plain, text_from_html) VALUES (?, ?, ?)",
                           arguments: [id, parsed.textPlain, parsed.textPlain == nil ? parsed.textFromHTML : nil])
        }
        return id
    }

    /// Gmail's thread ID when there is one; otherwise the first Message-ID in
    /// References (the thread's root), then In-Reply-To, then the message's own
    /// ID, so replies share a key with the message they answer (D-205).
    static func threadKey(raw: RawMessage, headers: MessageHeaders, rawHash: Data) -> String {
        if let thread = raw.gmailThreadID { return "g:\(thread)" }
        if let root = headers.references.first ?? headers.inReplyTo.first ?? headers.messageID { return "m:\(root)" }
        return "h:" + rawHash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func insertAddresses(_ db: Database, messageID: StoredMessageID, headers: MessageHeaders) throws {
        let roles: [(String, [EmailAddress])] = [
            ("from", headers.from), ("sender", headers.sender.map { [$0] } ?? []), ("reply_to", headers.replyTo),
            ("to", headers.to), ("cc", headers.cc), ("bcc", headers.bcc), ("delivered_to", headers.deliveredTo),
        ]
        for (role, addresses) in roles {
            for (position, address) in addresses.enumerated() {
                guard let addressID = try Self.addressID(db, address) else { continue }
                try db.execute(sql: """
                    INSERT INTO message_addresses (message_id, role, position, address_id, display_name)
                    VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                    """, arguments: [messageID, role, position, addressID, address.name])
            }
        }
    }

    static func addressID(_ db: Database, _ address: EmailAddress) throws -> Int64? {
        let normalised = address.normalised
        guard !normalised.isEmpty else { return nil }
        return try Int64.fetchOne(db, sql: """
            INSERT INTO addresses (address, domain) VALUES (?, ?)
            ON CONFLICT (address) DO UPDATE SET address = excluded.address
            RETURNING id
            """, arguments: [normalised, address.domain])
    }

    /// Records where this copy lives: its folder and UID, plus any Gmail labels.
    private func link(_ db: Database, messageID: StoredMessageID, raw: RawMessage) throws {
        let now = Int(Date().timeIntervalSince1970)
        let account = raw.key.accountID.rawValue
        let folderID = try Self.folderID(db, account: account, name: raw.key.folder, kind: "folder")
        try db.execute(sql: """
            INSERT INTO message_folders (message_id, folder_id, uid_validity, uid, last_seen_at)
            VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
            """, arguments: [messageID, folderID, Int64(raw.key.uidValidity), Int64(raw.key.uid), now])
        for label in raw.labels {
            let labelID = try Self.folderID(db, account: account, name: label, kind: "label")
            try db.execute(sql: """
                INSERT INTO message_folders (message_id, folder_id, last_seen_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [messageID, labelID, now])
        }
    }

    static func folderID(_ db: Database, account: String, name: String, kind: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            INSERT INTO folders (account_id, name, kind) VALUES (?, ?, ?)
            ON CONFLICT (account_id, kind, name) DO UPDATE SET name = excluded.name
            RETURNING id
            """, arguments: [account, name, kind])!
    }
}
