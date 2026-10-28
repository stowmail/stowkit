import Foundation
import GRDB
import Logging
import StowCore

public enum ImportError: Error, Equatable, CustomStringConvertible {
    /// The message belongs to an account the archive does not know. Register it first.
    case unknownAccount(AccountID)
    /// The stored file did not rebuild into the downloaded bytes. Nothing was recorded.
    case rebuildMismatch(RawMessageKey)

    public var description: String {
        switch self {
        case .unknownAccount(let id): "Account \(id) is not in the archive; register it before importing"
        case .rebuildMismatch(let key): "Message \(key) did not rebuild byte for byte from the archive; it was not recorded"
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
    /// The user removed this message from the archive earlier (D-033): it is
    /// not stored again, only its new location is remembered for a later restore.
    case tombstoned
}

/// Totals for an import run. Counts and sizes only, never content.
public struct ImportSummary: Sendable, Equatable, CustomStringConvertible {
    public var imported = 0
    public var linked = 0
    public var alreadyPresent = 0
    public var tombstoned = 0
    public var failed = 0
    public var bytes = 0
    public var seconds: Double = 0

    public init() {}

    public var messagesPerSecond: Double { seconds > 0 ? Double(imported + linked) / seconds : 0 }

    public var description: String {
        String(format: "%d imported, %d linked, %d already present, %d removed earlier, %d failed, %.1f MB in %.1f s (%.0f messages/s)",
               imported, linked, alreadyPresent, tombstoned, failed, Double(bytes) / 1_048_576, seconds, messagesPerSecond)
    }
}

/// A rules engine's verdict on a message, stored with it (D-041). Defined here
/// so storage does not depend on the rules module: whoever composes the two
/// (`StowEngine`) supplies a `RuleClassifier`.
public struct StoredRuleResult: Sendable, Equatable {
    public enum Suggestion: String, Sendable, CaseIterable {
        case keep
        case deprioritise
        case considerDeleting = "consider_deleting"
    }

    public var suggestion: Suggestion
    public var score: Int
    /// Signal identifiers that fired, for `stowmail remove --rule`, and
    /// `protectedMarker` when the message is protected (D-407).
    public var signals: [String]

    /// Written into `rule_signals` for protected mail. Not a signal ID, so `--rule` can never select it.
    public static let protectedMarker = "protected"

    public var isProtected: Bool { signals.contains(Self.protectedMarker) }

    public init(suggestion: Suggestion, score: Int, signals: [String]) {
        self.suggestion = suggestion
        self.score = score
        self.signals = signals
    }
}

/// Assesses a message from its headers and the account's own addresses.
public typealias RuleClassifier = @Sendable (_ headers: MessageHeaders, _ ownAddresses: Set<String>) -> StoredRuleResult

/// Turns raw messages into archive rows and encrypted files.
///
/// Each message is stored as a skeleton plus its attachment files (D-005,
/// D-029): attachments are decoded and stored once, and the message file
/// keeps everything else byte for byte with references where the attachment
/// bodies were. Before anything is recorded, the skeleton is rebuilt and
/// compared with the downloaded bytes; any attachment that does not rebuild
/// exactly stays inline. So every stored message rebuilds byte for byte.
///
/// Each message is written in one database transaction, after its encrypted
/// files are in place, so a crash leaves either the whole message or none of
/// its rows (an orphaned encrypted file is harmless and reused next time).
/// Its lookups run on the writer connection rather than the pool's readers,
/// so a long import does not slow down searches running at the same time
/// (D-206). Importing is idempotent: the same server copy is skipped before it is even
/// read, and the same bytes for the same account map to the same row
/// (`UNIQUE (account_id, raw_hash)`).
public final class Importer: Sendable {
    public let archive: Archive
    let parser = MIMEParser()
    let extractor: TextExtractor
    /// False only for measuring import speed without inline extraction (QA checklist).
    let extractText: Bool
    let classifier: RuleClassifier?
    let logger = Logger(label: "ee.getstow.store.import")

    public convenience init(archive: Archive, extractText: Bool = true, classifier: RuleClassifier? = nil) {
        self.init(archive: archive, extractText: extractText, classifier: classifier, extractor: TextExtractor())
    }

    /// Tests pass an extractor with a stand-in for PDFKit.
    init(archive: Archive, extractText: Bool = true, classifier: RuleClassifier? = nil, extractor: TextExtractor) {
        self.archive = archive
        self.extractText = extractText
        self.classifier = classifier
        self.extractor = extractor
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
                    case .tombstoned: summary.tombstoned += 1
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
        // Reader connections that lived through a long run of writes become slow (measured: ten times
        // slower FTS queries); closing idle ones lets searches start fresh.
        archive.database.releaseMemory()
        logger.info("import finished", metadata: ["summary": "\(summary)"])
        return summary
    }

    // MARK: - One message

    public func isAlreadyPresent(_ key: RawMessageKey) throws -> Bool {
        try archive.database.writeWithoutTransaction { db in try Self.isAlreadyPresent(db, key) }
    }

    static func isAlreadyPresent(_ db: Database, _ key: RawMessageKey) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                WHERE f.account_id = ? AND f.kind = 'folder' AND f.name = ? AND mf.uid_validity = ? AND mf.uid = ?)
            """, arguments: [key.accountID.rawValue, key.folder, Int64(key.uidValidity), Int64(key.uid)]) ?? false
    }

    /// Stores one message. `restoring` lets through a message the user removed
    /// earlier and asked to restore, and deletes its tombstone (D-033).
    /// `within` runs inside the transaction that records the outcome, so a
    /// caller can record its own progress atomically with the message.
    public func importMessage(
        _ raw: RawMessage,
        restoring: Bool = false,
        within: ((Database, ImportOutcome) throws -> Void)? = nil
    ) throws -> ImportOutcome {
        let key = raw.key
        guard let ownAddress = try accountAddress(key.accountID) else { throw ImportError.unknownAccount(key.accountID) }
        if try isAlreadyPresent(key) {
            if let within { try archive.database.write { db in try within(db, .alreadyPresent) } }
            return .alreadyPresent
        }

        let rawHash = archive.rawFiles.hash(of: raw.bytes)
        if !restoring, let tombstone = try tombstoneID(account: key.accountID, rawHash: rawHash) {
            try archive.database.write { db in
                try Self.rememberTombstonedCopy(db, tombstone: tombstone, key: key)
                try within?(db, .tombstoned)
            }
            return .tombstoned
        }
        if let existing = try existingMessage(account: key.accountID, rawHash: rawHash) {
            try archive.database.write { db in
                if restoring { try Self.deleteTombstone(db, account: key.accountID, rawHash: rawHash) }
                try Self.link(db, messageID: existing, raw: raw)
                try within?(db, .linked(existing))
            }
            return .linked(existing)
        }

        // Work outside the transaction: parse, store attachments, build and check the skeleton, extract text.
        let parsed = parser.parse(raw.bytes)
        let attachments = try parsed.attachments.map(prepare)
        let stored = try storeRawFile(raw, hash: rawHash, parsed: parsed)
        let rules = classifier?(parsed.headers, [ownAddress.lowercased()])

        return try archive.database.write { db -> ImportOutcome in
            // Another importer may have stored the same bytes meanwhile.
            if let existing = try Self.messageID(db, account: key.accountID, rawHash: rawHash) {
                try Self.link(db, messageID: existing, raw: raw)
                try within?(db, .linked(existing))
                return .linked(existing)
            }
            if restoring { try Self.deleteTombstone(db, account: key.accountID, rawHash: rawHash) }
            let id = try insertMessage(db, raw: raw, rawHash: rawHash, stored: stored, parsed: parsed, rules: rules,
                                       hasAttachments: attachments.contains { $0.parsed.disposition == .attachment })
            try insertAddresses(db, messageID: id, headers: parsed.headers)
            try insertAttachments(db, messageID: id, attachments: attachments)
            try Self.link(db, messageID: id, raw: raw)
            try SearchIndexWriter.index(db, messageID: id)
            try within?(db, .imported(id))
            return .imported(id)
        }
    }

    private func accountAddress(_ id: AccountID) throws -> String? {
        try archive.database.writeWithoutTransaction { db in
            try String.fetchOne(db, sql: "SELECT email FROM accounts WHERE id = ?", arguments: [id.rawValue])
        }
    }

    private func existingMessage(account: AccountID, rawHash: Data) throws -> StoredMessageID? {
        try archive.database.writeWithoutTransaction { db in try Self.messageID(db, account: account, rawHash: rawHash) }
    }

    static func messageID(_ db: Database, account: AccountID, rawHash: Data) throws -> StoredMessageID? {
        try StoredMessageID.fetchOne(db, sql: "SELECT id FROM messages WHERE account_id = ? AND raw_hash = ?",
                                     arguments: [account.rawValue, rawHash])
    }

    // MARK: - Skeleton

    struct StoredRaw {
        var state: String
        var storedSize: Int
        var keptInline: Int
    }

    /// Writes the message file: a skeleton when at least one attachment could
    /// be cut out, else the whole message. `RawCompaction.skeleton` has already
    /// proved the skeleton rebuilds into exactly these bytes.
    private func storeRawFile(_ raw: RawMessage, hash: Data, parsed: ParsedMessage) throws -> StoredRaw {
        let skeleton = RawCompaction.skeleton(raw.bytes, parsed: parsed, hashOf: archive.attachmentFiles.hash(of:))
        let result = try archive.rawFiles.write(skeleton?.skeleton ?? raw.bytes, hash: hash, skeleton: skeleton != nil)
        var state = skeleton == nil ? "full" : "skeleton"
        if !result.written {
            // The file was already there (the same bytes in another account, or a
            // crash before the rows were written): describe it as it is, and check it.
            state = try archive.rawFiles.readFile(hash).isSkeleton ? "skeleton" : "full"
            guard try archive.rawMessage(hash: hash, state: state) == raw.bytes else {
                throw ImportError.rebuildMismatch(raw.key)
            }
        }
        return StoredRaw(state: state, storedSize: result.storedSize,
                         keptInline: skeleton?.keptInline ?? RawCompaction.inlineCandidates(parsed))
    }

    // MARK: - Tombstones (D-033)

    private func tombstoneID(account: AccountID, rawHash: Data) throws -> Int64? {
        try archive.database.writeWithoutTransaction { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tombstones WHERE account_id = ? AND raw_hash = ?",
                               arguments: [account.rawValue, rawHash])
        }
    }

    static func rememberTombstonedCopy(_ db: Database, tombstone: Int64, key: RawMessageKey) throws {
        let folderID = try folderID(db, account: key.accountID.rawValue, name: key.folder, kind: "folder")
        try db.execute(sql: """
            INSERT INTO tombstone_copies (tombstone_id, folder_id, uid_validity, uid) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING
            """, arguments: [tombstone, folderID, Int64(key.uidValidity), Int64(key.uid)])
    }

    static func deleteTombstone(_ db: Database, account: AccountID, rawHash: Data) throws {
        try db.execute(sql: "DELETE FROM tombstones WHERE account_id = ? AND raw_hash = ?", arguments: [account.rawValue, rawHash])
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
        let known = try archive.database.writeWithoutTransaction { db in
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
        _ db: Database, raw: RawMessage, rawHash: Data, stored: StoredRaw, parsed: ParsedMessage,
        rules: StoredRuleResult?, hasAttachments: Bool
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
                raw_state, raw_stored_size, raw_inline_attachments, parse_status, parse_warnings, parser_version,
                rule_suggestion, rule_score, rule_signals, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                raw.key.accountID.rawValue, rawHash, headers.messageID,
                raw.gmailMessageID.map { Int64(bitPattern: $0) }, raw.gmailThreadID.map { Int64(bitPattern: $0) },
                Self.threadKey(raw: raw, headers: headers, rawHash: rawHash),
                Int(raw.internalDate.timeIntervalSince1970), headers.date.map { Int($0.timeIntervalSince1970) },
                headers.dateRaw, headers.subject, fromID, raw.size > 0 ? raw.size : raw.bytes.count, hasAttachments,
                stored.state, stored.storedSize, stored.keptInline, parsed.status.rawValue, warnings, MIMEParser.version,
                rules?.suggestion.rawValue, rules?.score, rules.map { $0.signals.joined(separator: ",") }, now,
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
        return "h:" + rawHash.prefix(8).hex
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

    /// Records where this copy lives: its folder, UID and flags, plus any Gmail
    /// labels. A message seen again at a new place (after a UIDVALIDITY change,
    /// or back from the Trash) has its copy moved there and is present again.
    static func link(_ db: Database, messageID: StoredMessageID, raw: RawMessage) throws {
        let now = Int(Date().timeIntervalSince1970)
        let account = raw.key.accountID.rawValue
        let folderID = try folderID(db, account: account, name: raw.key.folder, kind: "folder")
        try db.execute(sql: """
            INSERT INTO message_folders (message_id, folder_id, uid_validity, uid, flags, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (message_id, folder_id) DO UPDATE SET
                uid_validity = excluded.uid_validity, uid = excluded.uid, flags = excluded.flags,
                last_seen_at = excluded.last_seen_at, removed_from_server_at = NULL
            WHERE message_folders.uid_validity IS NOT excluded.uid_validity OR message_folders.removed_from_server_at IS NOT NULL
            """, arguments: [messageID, folderID, Int64(raw.key.uidValidity), Int64(raw.key.uid), flagText(raw.flags), now])
        for label in raw.labels {
            let labelID = try Self.folderID(db, account: account, name: label, kind: "label")
            try db.execute(sql: """
                INSERT INTO message_folders (message_id, folder_id, last_seen_at) VALUES (?, ?, ?)
                ON CONFLICT (message_id, folder_id) DO UPDATE SET removed_from_server_at = NULL, last_seen_at = excluded.last_seen_at
                """, arguments: [messageID, labelID, now])
        }
        try SourceStates.reclassify(db, messageID: messageID, at: now)
    }

    /// Flags as stored: sorted, space-separated. Empty when the copy has none.
    static func flagText(_ flags: [String]) -> String {
        flags.sorted().joined(separator: " ")
    }

    static func folderID(_ db: Database, account: String, name: String, kind: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            INSERT INTO folders (account_id, name, kind) VALUES (?, ?, ?)
            ON CONFLICT (account_id, kind, name) DO UPDATE SET name = excluded.name
            RETURNING id
            """, arguments: [account, name, kind])!
    }
}

/// Keeps `messages.source_state` in step with where the server still has a message (D-022, D-039).
enum SourceStates {
    /// From the message's folder copies: present if any copy outside a Trash
    /// folder is still on the server, trashed if only Trash copies are. With no
    /// copy left the state is left as it is: the caller classifies it.
    /// Returns the new state when it changed.
    @discardableResult
    static func reclassify(_ db: Database, messageID: Int64, at now: Int) throws -> SourceState? {
        let row = try Row.fetchOne(db, sql: """
            SELECT
                coalesce(max(CASE WHEN coalesce(f.special_use, '') != '\\trash' THEN 1 ELSE 0 END), 0) AS elsewhere,
                coalesce(max(CASE WHEN f.special_use = '\\trash' THEN 1 ELSE 0 END), 0) AS trash,
                (SELECT source_state FROM messages WHERE id = ?) AS current
            FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
            WHERE mf.message_id = ? AND f.kind = 'folder' AND mf.removed_from_server_at IS NULL
            """, arguments: [messageID, messageID])
        guard let row else { return nil }
        let elsewhere: Int = row["elsewhere"]
        let trash: Int = row["trash"]
        let current: String? = row["current"]
        let target: SourceState? = elsewhere == 1 ? .present : trash == 1 ? .trashed : nil
        guard let target, target.rawValue != current else { return nil }
        try set(db, messageID: messageID, target, at: now)
        return target
    }

    static func set(_ db: Database, messageID: Int64, _ state: SourceState, at now: Int) throws {
        try db.execute(sql: "UPDATE messages SET source_state = ?, source_state_at = ? WHERE id = ? AND source_state != ?",
                       arguments: [state.rawValue, now, messageID, state.rawValue])
    }
}
