import Foundation
import GRDB
import StowCore

/// What a retry round did. Counts only, never content.
public struct TextRetrySummary: Sendable, Equatable, CustomStringConvertible {
    /// Read in full this time, and no longer marked.
    public var read = 0
    /// Still not read, or tried the most times this build allows: marked with this build's version.
    public var marked = 0

    public init(read: Int = 0, marked: Int = 0) {
        self.read = read
        self.marked = marked
    }

    public var description: String { "\(read) read, \(marked) still marked" }
}

/// Retrying text Stow could not read, only after an update (D-481, D-502).
///
/// A marked message or attachment records the version of the parser or
/// extractor that failed on it. Only a newer one tries again, and with the same
/// limit as at import: each try is counted in its own transaction before
/// reading, and a row that has used up its tries is marked again with this
/// build's version, so this build never tries it again. Counts go back to 0
/// only when a row is marked or read (D-501).
extension Importer {
    /// Reads again every message marked by an older parser. Stops at the first
    /// one whose reading does not finish in time (`ImportError.retryTimedOut`):
    /// its try stays counted and the next round goes on from there.
    public func retryMarkedMessages() throws -> TextRetrySummary {
        let ids = try archive.database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM messages WHERE text_state = 'incomplete' AND text_marked_version < ? ORDER BY id
                """, arguments: [parserVersion])
        }
        var summary = TextRetrySummary()
        for id in ids {
            let earlier = try archive.database.write { db -> Int? in
                guard let earlier = try Int.fetchOne(db, sql: """
                    SELECT text_attempts FROM messages WHERE id = ? AND text_state = 'incomplete' AND text_marked_version < ?
                    """, arguments: [id, parserVersion]) else { return nil }
                try db.execute(sql: "UPDATE messages SET text_attempts = text_attempts + 1 WHERE id = ?", arguments: [id])
                return earlier
            }
            guard let earlier else { continue }
            if earlier >= Self.maximumAttempts {
                try archive.database.write { db in
                    try db.execute(sql: "UPDATE messages SET text_marked_version = ?, text_attempts = 0 WHERE id = ?",
                                   arguments: [parserVersion, id])
                }
                logger.warning("reading a marked message again never finished; marked with this version", metadata: ["message": "\(id)"])
                summary.marked += 1
                continue
            }
            do {
                try readAgain(id)
                summary.read += 1
            } catch let error as ImportError where error == .retryTimedOut(id) || error == .tooManyStuck {
                throw error
            } catch {
                // Finished with an error that is not the message's reading (a missing file, a full disk).
                try? archive.database.write { db in
                    try db.execute(sql: "UPDATE messages SET text_attempts = max(text_attempts - 1, 0) WHERE id = ?", arguments: [id])
                }
                logger.error("reading a marked message again failed", metadata: [
                    "message": "\(id)", "error": "\(Redact.scrub(String(describing: error)))",
                ])
            }
        }
        return summary
    }

    /// Parses a stored message from its own bytes and writes what the import
    /// would have: headers, addresses, body text, attachments, then marks it
    /// complete. The stored file is left exactly as it is.
    func readAgain(_ id: StoredMessageID) throws {
        guard let row = try archive.database.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT m.raw_hash, m.raw_state, m.thread_key, a.email, a.provider FROM messages m JOIN accounts a ON a.id = m.account_id
                WHERE m.id = ?
                """, arguments: [id])
        }) else { return }
        let bytes = try archive.rawMessage(hash: row["raw_hash"], state: row["raw_state"])
        let rawHash: Data = row["raw_hash"]
        let ownAddress: String = row["email"]
        let provider = Provider(rawValue: row["provider"])
        let prepared = try prepareWithinLimit(timedOut: .retryTimedOut(id)) { [self] in
            let parsed = parse(bytes)
            return (parsed: parsed, attachments: try parsed.attachments.map(prepare),
                    rules: classifier?(parsed.headers, [ownAddress.lowercased()]))
        }
        let parsed = prepared.parsed
        let headers = parsed.headers
        let senderDMARC = Self.senderDMARC(headers, provider: provider)
        // A Gmail thread ID never changes; otherwise the key comes from the headers now they can be read.
        let oldKey: String? = row["thread_key"]
        let threadKey = oldKey.flatMap { $0.hasPrefix("g:") ? $0 : nil }
            ?? headers.references.first.map { "m:\($0)" } ?? headers.inReplyTo.first.map { "m:\($0)" }
            ?? headers.messageID.map { "m:\($0)" } ?? "h:" + rawHash.prefix(8).hex
        let warnings = parsed.warnings.isEmpty ? nil : String(decoding: try JSONEncoder().encode(parsed.warnings), as: UTF8.self)

        try archive.database.write { db in
            try SearchIndexWriter.updating(db, messageIDs: [id]) {
                let fromID = try headers.from.first.flatMap { try Self.addressID(db, $0) }
                try db.execute(sql: """
                    UPDATE messages SET rfc822_message_id = ?, thread_key = ?, sent_date = ?, date_raw = ?, subject = ?,
                        from_address_id = ?, has_attachments = ?, raw_inline_attachments = ?,
                        parse_status = ?, parse_warnings = ?, parser_version = ?,
                        rule_suggestion = coalesce(?, rule_suggestion), rule_score = coalesce(?, rule_score),
                        rule_signals = coalesce(?, rule_signals), sender_dmarc = ?,
                        text_state = 'complete', text_marked_version = NULL, text_attempts = 0
                    WHERE id = ?
                    """, arguments: [
                        headers.messageID, threadKey, headers.date.map { Int($0.timeIntervalSince1970) }, headers.dateRaw,
                        headers.subject, fromID, prepared.attachments.contains { $0.parsed.disposition == .attachment },
                        row["raw_state"] as String == "full" ? RawCompaction.inlineCandidates(parsed) : 0,
                        parsed.status.rawValue, warnings, parserVersion,
                        prepared.rules?.suggestion.rawValue, prepared.rules?.score,
                        prepared.rules.map { $0.signals.joined(separator: ",") }, senderDMARC.rawValue, id,
                    ])
                try db.execute(sql: "DELETE FROM message_addresses WHERE message_id = ?", arguments: [id])
                try insertAddresses(db, messageID: id, headers: headers)
                try db.execute(sql: "DELETE FROM message_bodies WHERE message_id = ?", arguments: [id])
                if parsed.textPlain != nil || parsed.textFromHTML != nil {
                    try db.execute(sql: "INSERT INTO message_bodies (message_id, text_plain, text_from_html) VALUES (?, ?, ?)",
                                   arguments: [id, parsed.textPlain, parsed.textPlain == nil ? parsed.textFromHTML : nil])
                }
                try insertAttachments(db, messageID: id, attachments: prepared.attachments)
            }
        }
    }

    /// Reads again every attachment whose reading failed under an older
    /// extractor (`unsupported` with `text_failed_version` set). A PDF still
    /// runs under PDFKit's own time limit (D-495).
    public func retryUnreadAttachments() throws -> TextRetrySummary {
        let ids = try archive.database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM attachments WHERE text_status = 'unsupported' AND text_failed_version < ? ORDER BY id
                """, arguments: [extractorVersion])
        }
        var summary = TextRetrySummary()
        for id in ids {
            let now = Int(Date().timeIntervalSince1970)
            let found = try archive.database.write { db -> Row? in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT a.content_hash, a.mime_type, a.text_attempts,
                           (SELECT x.filename FROM message_attachments x WHERE x.attachment_id = a.id ORDER BY x.message_id, x.part_path LIMIT 1) AS filename
                    FROM attachments a WHERE a.id = ? AND a.text_status = 'unsupported' AND a.text_failed_version < ?
                    """, arguments: [id, extractorVersion]) else { return nil }
                try db.execute(sql: "UPDATE attachments SET text_attempts = text_attempts + 1, text_last_attempt_at = ? WHERE id = ?",
                               arguments: [now, id])
                return row
            }
            guard let found else { continue }
            var result = ExtractionResult.unreadable
            if found["text_attempts"] as Int >= TextExtractor.maximumAttempts {
                logger.warning("reading an attachment again never finished; marked with this version", metadata: ["attachment": "\(id)"])
            } else {
                let data = try archive.attachmentFiles.read(found["content_hash"])
                let attachment = ParsedAttachment(partPath: "", filename: found["filename"], declaredMimeType: found["mime_type"] ?? "",
                                                  disposition: .attachment, contentID: nil, data: data, encodedRange: 0..<0,
                                                  transferEncoding: nil)
                result = extractor.extract(attachment)
            }
            try archive.database.write { db in
                let messages = try SearchIndexWriter.messages(containing: id, db)
                try SearchIndexWriter.updating(db, messageIDs: messages) {
                    if let text = result.text, let method = result.method {
                        try db.execute(sql: """
                            INSERT INTO attachment_text (attachment_id, text, method, extractor_version, extracted_at)
                            VALUES (?, ?, ?, ?, ?)
                            ON CONFLICT (attachment_id) DO UPDATE SET text = excluded.text, method = excluded.method,
                                extractor_version = excluded.extractor_version, extracted_at = excluded.extracted_at
                            """, arguments: [id, text, method.rawValue, extractorVersion, now])
                    }
                    try db.execute(sql: "UPDATE attachments SET text_status = ?, text_failed_version = ?, text_attempts = 0 WHERE id = ?",
                                   arguments: [result.status.rawValue, result.failed ? extractorVersion : nil, id])
                }
            }
            if result.failed { summary.marked += 1 } else { summary.read += 1 }
        }
        return summary
    }
}
