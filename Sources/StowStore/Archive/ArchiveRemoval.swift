import Foundation
import GRDB
import StowCore

/// Which archived messages a tidy-up acts on (D-020, D-033).
public enum RemovalSelector: Sendable, Equatable {
    /// Messages where this rules signal fired (a `SignalID` raw value, for example `listUnsubscribe`).
    case signal(String)
    /// Messages the rules gave this suggestion.
    case suggestion(StoredRuleResult.Suggestion)
    /// Messages from this address, or from this domain and its subdomains.
    case sender(String)
    /// Messages in this state at the provider, for example marked as spam (D-022).
    case sourceState(SourceState)
    /// Emails the user picked from the list or the reader (D-422, R14). Protected
    /// mail is included, since the user chose it; IDs no longer in the archive are skipped.
    case messages([StoredMessageID])
    /// Mail in this state at the provider that the account's retention does not explain (D-022):
    /// for trashed and gone, only mail from after the account's retention cutoff (all of it when no
    /// retention is set); for spam, all of it. What Tidy up offers as "you deleted these recently".
    /// Protected mail included, as for `sourceState`. Recorded like `sourceState`.
    case recentSourceState(SourceState)

    /// How the selector is recorded on each tombstone: no addresses for rules.
    public var reason: String {
        switch self {
        case .signal(let signal): "rule:\(signal)"
        case .suggestion(let suggestion): "suggestion:\(suggestion.rawValue)"
        case .sender(let sender): "sender:\(sender.lowercased())"
        case .sourceState(let state), .recentSourceState(let state): "source:\(state.rawValue)"
        case .messages: "chosen"
        }
    }
}

/// What a removal would do, shown before it runs.
public struct RemovalPlan: Sendable, Equatable {
    public var messageIDs: [StoredMessageID]
    /// What the provider reports for those messages.
    public var bytes: Int
    /// Distinct sender domains among them, for the summary.
    public var senderDomains: Int
    /// Protected messages the selector matched but left out: a rule or
    /// suggestion never removes protected mail (D-407).
    public var protectedLeftOut = 0
    /// Protected messages in `messageIDs`: only when the user named the sender
    /// or the source state themselves.
    public var protectedIncluded = 0

    public init(messageIDs: [StoredMessageID], bytes: Int, senderDomains: Int, protectedLeftOut: Int = 0, protectedIncluded: Int = 0) {
        self.messageIDs = messageIDs
        self.bytes = bytes
        self.senderDomains = senderDomains
        self.protectedLeftOut = protectedLeftOut
        self.protectedIncluded = protectedIncluded
    }
}

public struct RemovalResult: Sendable, Equatable {
    public var messages = 0
    /// Message and attachment files deleted because nothing else used them.
    public var filesDeleted = 0
    public var bytesFreed = 0
    /// The tombstone written for each removed message, for an immediate Undo (UI-20).
    public var tombstones: [Int64] = []
}

/// One removed message, as `stowmail removed` lists it.
public struct Tombstone: Sendable, Equatable {
    public var id: Int64
    public var account: AccountID
    public var date: Date
    public var sender: String?
    public var reason: String
    public var removedAt: Date
    public var restoreRequestedAt: Date?
    /// Whether `requestRestore` can queue it: a place where the server last had it is in a folder
    /// still synced at the same UIDVALIDITY. False means Put back cannot find it.
    public var restorable: Bool
}

/// Removing mail from the archive, and putting it back (D-020, D-033).
///
/// Removal never touches the mailbox. It deletes the message's rows, its
/// skeleton file and any attachment file no other message uses, and keeps a
/// small tombstone (account, provider IDs, Message-ID, date, sender, the reason,
/// and where it was on the server) so sync never downloads it again. While the
/// provider still has the message, `requestRestore` puts it back in the
/// download queue.
public struct ArchiveRemoval: Sendable {
    public let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    /// The messages a selector picks, optionally for one account.
    /// `text` matched literally inside a LIKE pattern with `ESCAPE '\'`, so a
    /// `%` or `_` typed in a selector cannot widen what is removed (security review).
    static func likeLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// True for a message whose stored rules result marks it protected (D-407).
    static let isProtectedSQL = "(',' || coalesce(m.rule_signals, '') || ',') LIKE '%,\(StoredRuleResult.protectedMarker),%'"

    public func plan(_ selector: RemovalSelector, account: AccountID? = nil, now: Date = Date()) throws -> RemovalPlan {
        try archive.database.read { db in
            var conditions: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if let account {
                conditions.append("m.account_id = ?")
                arguments.append(account.rawValue)
            }
            switch selector {
            case .signal(let signal):
                conditions.append("(',' || coalesce(m.rule_signals, '') || ',') LIKE ? ESCAPE '\\'")
                arguments.append("%,\(Self.likeLiteral(signal)),%")
            case .suggestion(let suggestion):
                conditions.append("m.rule_suggestion = ?")
                arguments.append(suggestion.rawValue)
            case .sender(let sender):
                let value = sender.trimmingCharacters(in: .whitespaces).lowercased()
                if value.contains("@") {
                    conditions.append("a.address = ?")
                    arguments.append(value)
                } else {
                    let domain = value.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                    conditions.append("(a.domain = ? OR a.domain LIKE ? ESCAPE '\\')")
                    arguments += [domain, "%.\(Self.likeLiteral(domain))"]
                }
            case .sourceState(let state):
                conditions.append("m.source_state = ?")
                arguments.append(state.rawValue)
            case .recentSourceState(let state):
                conditions.append("m.source_state = ?")
                arguments.append(state.rawValue)
                if state != .spam {
                    // Leave out what each account's retention explains (D-022, D-039), as TidySummary counts it.
                    for (accountID, cutoff) in try Self.retentionCutoffs(db, now: now) {
                        conditions.append("NOT (m.account_id = ? AND m.internal_date < ?)")
                        arguments += [accountID, cutoff]
                    }
                }
            case .messages(let ids):
                // Bound as values, never spliced into the SQL; in chunks well under SQLite's variable limit.
                return try Self.plan(db, chosen: ids, account: account)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id, m.size, a.domain, \(Self.isProtectedSQL) AS protected
                FROM messages m LEFT JOIN addresses a ON a.id = m.from_address_id
                WHERE \(conditions.joined(separator: " AND ")) ORDER BY m.id
                """, arguments: StatementArguments(arguments))
            // Rules and suggestions never pick protected mail; a sender or source state the user names does (D-407).
            let leavesProtectedOut: Bool = switch selector {
            case .signal, .suggestion: true
            case .sender, .sourceState, .recentSourceState, .messages: false
            }
            let chosen = leavesProtectedOut ? rows.filter { !($0["protected"] as Bool) } : rows
            return RemovalPlan(
                messageIDs: chosen.map { $0["id"] },
                bytes: chosen.reduce(0) { $0 + ($1["size"] as Int) },
                senderDomains: Set(chosen.compactMap { $0["domain"] as String? }).count,
                protectedLeftOut: rows.count - chosen.count,
                protectedIncluded: chosen.filter { $0["protected"] as Bool }.count
            )
        }
    }

    /// Each account's retention cutoff (D-034) as a stored `internal_date`: `now` less its
    /// retention months. Accounts without a retention setting are absent. Shared with
    /// `TidySummary`, so "older than your retention" means the same thing in both.
    public static func retentionCutoffs(_ db: Database, now: Date) throws -> [String: Int64] {
        var cutoffs: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, retention_months FROM accounts WHERE retention_months IS NOT NULL") {
            if let months: Int = row["retention_months"],
               let cutoff = Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: now) {
                cutoffs[row["id"]] = Int64(cutoff.timeIntervalSince1970)
            }
        }
        return cutoffs
    }

    /// The plan for chosen messages: every one still in the archive (and in `account`, if given),
    /// protected or not, counted as `protectedIncluded`.
    static func plan(_ db: Database, chosen ids: [StoredMessageID], account: AccountID?) throws -> RemovalPlan {
        var rows: [Row] = []
        let unique = Array(Set(ids)).sorted()
        for start in stride(from: 0, to: unique.count, by: 500) {
            let chunk = Array(unique[start..<min(start + 500, unique.count)])
            var sql = """
                SELECT m.id, m.size, a.domain, \(isProtectedSQL) AS protected
                FROM messages m LEFT JOIN addresses a ON a.id = m.from_address_id
                WHERE m.id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ", ")))
                """
            var arguments: [any DatabaseValueConvertible] = chunk
            if let account {
                sql += " AND m.account_id = ?"
                arguments.append(account.rawValue)
            }
            rows += try Row.fetchAll(db, sql: sql + " ORDER BY m.id", arguments: StatementArguments(arguments))
        }
        return RemovalPlan(
            messageIDs: rows.map { $0["id"] },
            bytes: rows.reduce(0) { $0 + ($1["size"] as Int) },
            senderDomains: Set(rows.compactMap { $0["domain"] as String? }).count,
            protectedIncluded: rows.filter { $0["protected"] as Bool }.count)
    }

    /// Removes the messages, writing a tombstone for each. Database first, in
    /// batches; files afterwards, only once nothing refers to them. An
    /// interruption between the two leaves unused files, which `stowmail verify`
    /// reports and `sweepUnusedFiles` deletes.
    ///
    /// Each batch's commit is made durable before its first file is deleted
    /// (A-11): the archive's usual commit reaches the disk only at the next
    /// checkpoint, so after a power cut the removed rows could come back
    /// pointing at files already gone.
    public func remove(_ messageIDs: [StoredMessageID], reason: String, progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> RemovalResult {
        var result = RemovalResult()
        for start in stride(from: 0, to: messageIDs.count, by: 200) {
            let batch = Array(messageIDs[start..<min(start + 200, messageIDs.count)])
            var rawFiles: [Data] = []
            var attachmentFiles: [Data] = []
            try archive.database.writeWithoutTransaction { db in
                try archive.durably(db) {
                    try db.inTransaction {
                        rawFiles = []
                        attachmentFiles = []
                        var batchResult = result
                        for id in batch {
                            guard let unused = try removeOne(db, id: id, reason: reason) else { continue }
                            rawFiles += unused.raw
                            attachmentFiles += unused.attachments
                            batchResult.messages += 1
                            batchResult.tombstones.append(unused.tombstone)
                        }
                        result = batchResult
                        return .commit
                    }
                }
            }
            result.bytesFreed += deleteFiles(rawFiles, in: archive.rawFiles) + deleteFiles(attachmentFiles, in: archive.attachmentFiles)
            result.filesDeleted += rawFiles.count + attachmentFiles.count
            progress?(min(start + batch.count, messageIDs.count), messageIDs.count)
        }
        return result
    }

    /// One message's rows out and its tombstone in. Returns the files it leaves unused.
    private func removeOne(_ db: Database, id: StoredMessageID, reason: String) throws -> (raw: [Data], attachments: [Data], tombstone: Int64)? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT m.account_id, m.raw_hash, m.gmail_msgid, m.rfc822_message_id, m.internal_date, m.size, a.address
            FROM messages m LEFT JOIN addresses a ON a.id = m.from_address_id WHERE m.id = ?
            """, arguments: [id]) else { return nil }
        let account: String = row["account_id"]
        let rawHash: Data = row["raw_hash"]
        let copies = try Row.fetchAll(db, sql: """
            SELECT mf.folder_id, mf.uid_validity, mf.uid FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
            WHERE mf.message_id = ? AND f.kind = 'folder' AND mf.uid IS NOT NULL
            """, arguments: [id])
        let attachmentIDs = try Int64.fetchAll(db, sql: "SELECT DISTINCT attachment_id FROM message_attachments WHERE message_id = ?",
                                               arguments: [id])

        try SearchIndexWriter.remove(db, messageID: id)
        let now = Int(Date().timeIntervalSince1970)
        let tombstone = try Int64.fetchOne(db, sql: """
            INSERT INTO tombstones (account_id, raw_hash, gmail_msgid, rfc822_message_id, internal_date, size, sender, reason, removed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (account_id, raw_hash) DO UPDATE SET reason = excluded.reason, removed_at = excluded.removed_at,
                restore_requested_at = NULL
            RETURNING id
            """, arguments: [account, rawHash, row["gmail_msgid"] as Int64?, row["rfc822_message_id"] as String?,
                             row["internal_date"] as Int64, row["size"] as Int64, row["address"] as String?, reason, now])!
        for copy in copies {
            try db.execute(sql: """
                INSERT INTO tombstone_copies (tombstone_id, folder_id, uid_validity, uid) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [tombstone, copy["folder_id"] as Int64, copy["uid_validity"] as Int64, copy["uid"] as Int64])
        }
        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])

        var unusedAttachments: [Data] = []
        for attachment in attachmentIDs {
            let used = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM message_attachments WHERE attachment_id = ?)",
                                         arguments: [attachment]) ?? true
            guard !used, let hash = try Data.fetchOne(db, sql: "SELECT content_hash FROM attachments WHERE id = ?", arguments: [attachment])
            else { continue }
            try db.execute(sql: "DELETE FROM attachments WHERE id = ?", arguments: [attachment])
            unusedAttachments.append(hash)
        }
        // The same bytes in another account share one message file.
        let rawUsed = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE raw_hash = ?)", arguments: [rawHash]) ?? true
        return (rawUsed ? [] : [rawHash], unusedAttachments, tombstone)
    }

    private func deleteFiles(_ hashes: [Data], in store: EncryptedFileStore) -> Int {
        var bytes = 0
        for hash in hashes {
            bytes += EncryptedFileStore.fileSize(store.url(for: hash)) ?? 0
            try? archive.diskSync.note(.unlink(store.url(for: hash).path))
            try? store.delete(hash)
        }
        return bytes
    }

    /// Deletes message and attachment files no database row refers to (left by
    /// an interrupted sync or removal). Call only while holding the writer lock.
    /// Returns how many were deleted.
    @discardableResult
    public func sweepUnusedFiles() throws -> Int {
        let (raw, attachments) = try archive.database.read { db in
            (Set(try Data.fetchAll(db, sql: "SELECT DISTINCT raw_hash FROM messages")),
             Set(try Data.fetchAll(db, sql: "SELECT content_hash FROM attachments")))
        }
        let unusedRaw = archive.rawFiles.allHashes().filter { !raw.contains($0) }
        let unusedAttachments = archive.attachmentFiles.allHashes().filter { !attachments.contains($0) }
        _ = deleteFiles(unusedRaw, in: archive.rawFiles) + deleteFiles(unusedAttachments, in: archive.attachmentFiles)
        return unusedRaw.count + unusedAttachments.count
    }

    // MARK: - Removed mail

    public func tombstones(account: AccountID? = nil) throws -> [Tombstone] {
        try archive.database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.*, EXISTS (\(Self.restorablePlaceSQL)) AS restorable FROM tombstones t
                WHERE ? IS NULL OR t.account_id = ? ORDER BY t.removed_at DESC, t.internal_date DESC
                """, arguments: [account?.rawValue, account?.rawValue]).map { row in
                Tombstone(
                    id: row["id"], account: AccountID(rawValue: row["account_id"]),
                    date: Date(timeIntervalSince1970: TimeInterval(row["internal_date"] as Int64)),
                    sender: row["sender"], reason: row["reason"],
                    removedAt: Date(timeIntervalSince1970: TimeInterval(row["removed_at"] as Int64)),
                    restoreRequestedAt: (row["restore_requested_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    restorable: row["restorable"])
            }
        }
    }

    /// A place `requestRestore` can queue tombstone `t` at: its folder still synced, at the same UIDVALIDITY.
    static let restorablePlaceSQL = """
        SELECT 1 FROM tombstone_copies c
        JOIN sync_state s ON s.folder_id = c.folder_id AND s.uid_validity = c.uid_validity
        JOIN folders f ON f.id = c.folder_id AND f.skipped_reason IS NULL
        WHERE c.tombstone_id = t.id
        """

    /// Puts removed messages back in the download queue, at the place the
    /// server last had them. Messages whose folder has since changed
    /// UIDVALIDITY (or is no longer synced) cannot be found that way and are
    /// counted as unavailable. The next sync downloads the rest; a message
    /// the provider has deleted meanwhile simply drops out of the queue.
    public func requestRestore(_ tombstoneIDs: [Int64]) throws -> (queued: Int, unavailable: Int) {
        try archive.database.write { db in
            var queued = 0
            var unavailable = 0
            let now = Int(Date().timeIntervalSince1970)
            for id in tombstoneIDs {
                guard let tombstone = try Row.fetchOne(db, sql: "SELECT size, internal_date, gmail_msgid FROM tombstones WHERE id = ?",
                                                       arguments: [id]) else { continue }
                let copies = try Row.fetchAll(db, sql: """
                    SELECT c.folder_id, c.uid_validity, c.uid FROM tombstone_copies c
                    JOIN sync_state s ON s.folder_id = c.folder_id AND s.uid_validity = c.uid_validity
                    JOIN folders f ON f.id = c.folder_id AND f.skipped_reason IS NULL
                    WHERE c.tombstone_id = ? ORDER BY c.folder_id LIMIT 1
                    """, arguments: [id])
                guard let copy = copies.first else {
                    unavailable += 1
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO download_queue (folder_id, uid_validity, uid, size, internal_date, priority, gmail_msgid, restore, queued_at)
                    VALUES (?, ?, ?, ?, ?, 0, ?, 1, ?)
                    ON CONFLICT (folder_id, uid_validity, uid) DO UPDATE SET restore = 1, state = 'queued', attempts = 0,
                        last_run_id = NULL, priority = 0
                    """, arguments: [copy["folder_id"] as Int64, copy["uid_validity"] as Int64, copy["uid"] as Int64,
                                     tombstone["size"] as Int64, tombstone["internal_date"] as Int64,
                                     tombstone["gmail_msgid"] as Int64?, now])
                try db.execute(sql: "UPDATE tombstones SET restore_requested_at = ? WHERE id = ?", arguments: [now, id])
                queued += 1
            }
            return (queued, unavailable)
        }
    }
}
