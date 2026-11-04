import Foundation
import GRDB
import StowCore

/// One message read from a file (an mbox, D-559), ready for `Importer.importFromFile`.
/// Never log it: `bytes` is the message.
public struct FileMessage: Sendable {
    public var account: AccountID
    /// The `import_batches` row it belongs to (D-564).
    public var batch: Int64
    /// The message, with the file's framing undone.
    public var bytes: Data
    /// The date on the mbox `From ` line, when it has one: the arrival date (D-566).
    public var separatorDate: Date?
    /// Stow label names from Takeout's `X-Gmail-Labels` (D-566).
    public var labels: [String]
    /// Takeout's `X-GM-THRID`.
    public var gmailThreadID: UInt64?
    /// `spam` or `trashed` from Takeout's Spam and Trash markers, else `present`.
    public var sourceState: SourceState

    public init(account: AccountID, batch: Int64, bytes: Data, separatorDate: Date? = nil, labels: [String] = [],
                gmailThreadID: UInt64? = nil, sourceState: SourceState = .present) {
        self.account = account
        self.batch = batch
        self.bytes = bytes
        self.separatorDate = separatorDate
        self.labels = labels
        self.gmailThreadID = gmailThreadID
        self.sourceState = sourceState
    }
}

/// Why a message from a file was not stored although it could be read (D-565).
public enum FileDuplicate: String, Sendable, Equatable, CaseIterable {
    /// The account already has these exact bytes.
    case sameBytes
    /// The account already has a message with the same Message-ID and the same content.
    case sameMessage
    /// The user removed this message from the archive earlier (D-033).
    case removedEarlier
}

/// What happened to one message from a file.
public enum FileImportOutcome: Sendable, Equatable {
    case imported(StoredMessageID)
    /// Reading it did not finish in time, so it was stored whole and marked (D-502).
    case storedUnread(StoredMessageID)
    case duplicate(FileDuplicate)
}

extension Importer {
    /// Most stored messages sharing a Message-ID that are compared with a new one.
    static let maximumCandidates = 20
    /// A removed message matches by Message-ID only if its arrival date is this close (D-565).
    static let tombstoneDateTolerance: Int64 = 86_400

    /// Stores one message from a file into its account as imported (D-562),
    /// unless the duplicate rule finds it already there (D-565). Nothing is
    /// linked to a server folder: the message has no copy Stow has seen on a
    /// server, so it never counts towards coverage or the safe-to-delete counts
    /// (D-567). `within` runs inside the transaction that records the outcome,
    /// so the caller's batch offset moves with it. `raiseReaderLevel` raises the
    /// archive's reader level in that transaction (D-563).
    public func importFromFile(
        _ message: FileMessage,
        raiseReaderLevel: Bool = true,
        within: ((Database, FileImportOutcome) throws -> Void)? = nil
    ) throws -> FileImportOutcome {
        guard let (ownAddress, provider) = try account(message.account) else { throw ImportError.unknownAccount(message.account) }
        let rawHash = archive.rawFiles.hash(of: message.bytes)
        if try existingMessage(account: message.account, rawHash: rawHash) != nil {
            return try record(.duplicate(.sameBytes), within: within)
        }
        if try tombstoneID(account: message.account, rawHash: rawHash) != nil {
            return try record(.duplicate(.removedEarlier), within: within)
        }

        // Reading and comparing run under the same time limit as at sync (D-502).
        let key = RawMessageKey(accountID: message.account, folder: "", uidValidity: 0, uid: 0)
        let reading: (parsed: ParsedMessage, duplicate: FileDuplicate?)
        do {
            reading = try prepareWithinLimit(timedOut: .timedOut(key)) { [self] in
                let parsed = parse(message.bytes)
                return (parsed, try duplicate(of: parsed, in: message, date: arrival(message, parsed.headers)))
            }
        } catch ImportError.timedOut {
            return try storeUnreadFromFile(message, rawHash: rawHash, raiseReaderLevel: raiseReaderLevel, within: within)
        }
        if let duplicate = reading.duplicate { return try record(.duplicate(duplicate), within: within) }

        let raw = RawMessage(key: key, labels: message.labels, gmailThreadID: message.gmailThreadID,
                             internalDate: arrival(message, reading.parsed.headers), size: message.bytes.count, bytes: message.bytes)
        let prepared: Prepared
        do {
            prepared = try prepareWithinLimit(timedOut: .timedOut(key)) { [self] in
                try prepareMessage(raw, hash: rawHash, ownAddress: ownAddress, provider: provider, parsed: reading.parsed)
            }
        } catch ImportError.timedOut {
            return try storeUnreadFromFile(message, rawHash: rawHash, raiseReaderLevel: raiseReaderLevel, within: within)
        }
        if prepared.stored.written || prepared.attachments.contains(where: \.written) {
            try archive.diskSync.barrier(archive.location.root)
        }
        let outcome = try archive.database.write { db -> FileImportOutcome in
            if try Self.messageID(db, account: message.account, rawHash: rawHash) != nil {
                try within?(db, .duplicate(.sameBytes))
                return .duplicate(.sameBytes)
            }
            if raiseReaderLevel { try ArchiveSchema.requireReaderLevel(ArchiveSchema.importedMailReaderLevel, db) }
            let id = try insertMessage(db, raw: raw, rawHash: rawHash, prepared: prepared,
                                       imported: (message.batch, message.sourceState))
            try insertAddresses(db, messageID: id, headers: prepared.parsed.headers)
            try insertAttachments(db, messageID: id, attachments: prepared.attachments)
            try Self.linkLabels(db, messageID: id, account: message.account, labels: message.labels)
            try SearchIndexWriter.index(db, messageID: id)
            try within?(db, .imported(id))
            return .imported(id)
        }
        try archive.diskSync.note(.commit)
        return outcome
    }

    /// The arrival date: the `From ` line's, else the Date header's, else now (D-566).
    func arrival(_ message: FileMessage, _ headers: MessageHeaders) -> Date {
        message.separatorDate ?? headers.date ?? Date()
    }

    private func record(_ outcome: FileImportOutcome, within: ((Database, FileImportOutcome) throws -> Void)?) throws -> FileImportOutcome {
        if let within { try archive.database.write { db in try within(db, outcome) } }
        return outcome
    }

    /// The duplicate rule after the bytes did not match (D-565): a removed
    /// message with the same Message-ID and an arrival date within a day, or a
    /// stored one with the same Message-ID and the same content.
    func duplicate(of parsed: ParsedMessage, in message: FileMessage, date: Date) throws -> FileDuplicate? {
        guard let messageID = parsed.headers.messageID else { return nil }
        let (removed, candidates) = try archive.database.writeWithoutTransaction { db in
            (try Int64.fetchAll(db, sql: "SELECT internal_date FROM tombstones WHERE account_id = ? AND rfc822_message_id = ?",
                                arguments: [message.account.rawValue, messageID]),
             try Row.fetchAll(db, sql: """
                SELECT raw_hash, raw_state FROM messages WHERE rfc822_message_id = ? AND account_id = ? ORDER BY id LIMIT ?
                """, arguments: [messageID, message.account.rawValue, Self.maximumCandidates]))
        }
        let arrived = Int64(date.timeIntervalSince1970)
        if removed.contains(where: { abs($0 - arrived) <= Self.tombstoneDateTolerance }) { return .removedEarlier }
        guard !candidates.isEmpty else { return nil }
        let fingerprint = contentFingerprint(parsed)
        for candidate in candidates {
            let stored = try archive.rawMessage(hash: candidate["raw_hash"], state: candidate["raw_state"])
            if contentFingerprint(parse(stored)) == fingerprint { return .sameMessage }
        }
        return nil
    }

    /// A keyed hash of what a reader sees (D-565): the decoded plain text, the
    /// text from HTML and the attachments' own keyed hashes, sorted. Blind to
    /// transfer encoding and to headers, so a Takeout copy and the IMAP copy of
    /// the same message match. Kept in memory only.
    func contentFingerprint(_ parsed: ParsedMessage) -> Data {
        var input = Data()
        func append(_ part: Data?) {
            guard let part else { input.append(0); return }
            input.append(1)
            withUnsafeBytes(of: UInt64(part.count).bigEndian) { input.append(contentsOf: $0) }
            input.append(part)
        }
        append(parsed.textPlain.map { Data($0.utf8) })
        append(parsed.textFromHTML.map { Data($0.utf8) })
        for hash in parsed.attachments.map({ archive.attachmentFiles.hash(of: $0.data) }).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            append(hash)
        }
        return archive.rawFiles.hash(of: input)
    }

    /// Links Takeout's labels. A file has no server folder, so only labels.
    static func linkLabels(_ db: Database, messageID: StoredMessageID, account: AccountID, labels: [String]) throws {
        let now = Int(Date().timeIntervalSince1970)
        for label in labels {
            let labelID = try folderID(db, account: account.rawValue, name: label, kind: "label")
            try db.execute(sql: "INSERT INTO message_folders (message_id, folder_id, last_seen_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                           arguments: [messageID, labelID, now])
        }
    }

    /// Stores a message whose reading did not finish in time, whole and marked,
    /// as `storeUnread` does for sync (D-481, D-502).
    private func storeUnreadFromFile(
        _ message: FileMessage, rawHash: Data, raiseReaderLevel: Bool, within: ((Database, FileImportOutcome) throws -> Void)?
    ) throws -> FileImportOutcome {
        let key = RawMessageKey(accountID: message.account, folder: "", uidValidity: 0, uid: 0)
        let raw = RawMessage(key: key, labels: message.labels, gmailThreadID: message.gmailThreadID,
                             internalDate: message.separatorDate ?? Date(), size: message.bytes.count, bytes: message.bytes)
        let stored = try storeRawFile(raw, hash: rawHash, skeleton: nil, keptInline: 0)
        if stored.written { try archive.diskSync.barrier(archive.location.root) }
        let outcome = try archive.database.write { db -> FileImportOutcome in
            if try Self.messageID(db, account: message.account, rawHash: rawHash) != nil {
                try within?(db, .duplicate(.sameBytes))
                return .duplicate(.sameBytes)
            }
            if raiseReaderLevel { try ArchiveSchema.requireReaderLevel(ArchiveSchema.importedMailReaderLevel, db) }
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                INSERT INTO messages (
                    account_id, raw_hash, gmail_thrid, thread_key, internal_date, size,
                    raw_state, raw_stored_size, parse_status, parse_warnings, parser_version,
                    text_state, text_marked_version, sender_dmarc, imported_at,
                    origin, import_batch_id, source_state, source_state_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'failed', ?, ?, 'incomplete', ?, 'none', ?, 'imported', ?, ?, ?)
                """, arguments: [
                    message.account.rawValue, rawHash, message.gmailThreadID.map { Int64(bitPattern: $0) },
                    Self.threadKey(raw: raw, headers: MessageHeaders(), rawHash: rawHash),
                    Int(raw.internalDate.timeIntervalSince1970), message.bytes.count,
                    stored.state, stored.storedSize, Self.unreadWarnings, parserVersion, parserVersion, now,
                    message.batch, message.sourceState.rawValue, message.sourceState == .present ? nil : now,
                ])
            let id = db.lastInsertedRowID
            try Self.linkLabels(db, messageID: id, account: message.account, labels: message.labels)
            try SearchIndexWriter.index(db, messageID: id)
            try within?(db, .storedUnread(id))
            return .storedUnread(id)
        }
        try archive.diskSync.note(.commit)
        return outcome
    }
}
