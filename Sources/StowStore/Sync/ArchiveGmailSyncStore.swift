import Foundation
import GRDB
import StowCore

/// The archive's side of Gmail API sync (D-591): `gmail_queue`, `gmail_sync_state`,
/// and All Mail copies with no UID. Downloaded messages arrive through
/// `write` with a `RawMessageKey.gmailAPI` key and leave the queue in the
/// transaction that stores them, as IMAP ones do.
extension ArchiveSyncStore: GmailSyncStateStore {
    /// The name a Gmail API account's All Mail folder gets when IMAP never
    /// recorded one. Existing accounts keep the name IMAP stored.
    public static let gmailAllMailName = "[Gmail]/All Mail"

    public func gmailAllMail(_ account: AccountID) async throws -> String {
        try await database.write { db in try Self.allMail(db, account: account).name }
    }

    /// The account's All Mail folder row (special use `\all`), made if missing.
    static func allMail(_ db: Database, account: AccountID) throws -> (id: Int64, name: String) {
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, name FROM folders WHERE account_id = ? AND kind = 'folder' AND special_use = '\\all' ORDER BY id LIMIT 1
            """, arguments: [account.rawValue]) {
            return (row["id"], row["name"])
        }
        let id = try Int64.fetchOne(db, sql: """
            INSERT INTO folders (account_id, name, kind, special_use) VALUES (?, ?, 'folder', '\\all')
            ON CONFLICT (account_id, kind, name) DO UPDATE SET special_use = excluded.special_use
            RETURNING id
            """, arguments: [account.rawValue, gmailAllMailName])!
        return (id, gmailAllMailName)
    }

    public func gmailState(_ account: AccountID) async throws -> GmailSyncState? {
        try await database.read { db in
            try Self.gmailStateRow(db, account: account).map {
                GmailSyncState(
                    historyID: ($0["history_id"] as Int64?).map { UInt64(bitPattern: $0) },
                    fullListingCompletedAt: Self.date($0["full_listing_completed_at"]),
                    lastFullCheckAt: Self.date($0["last_full_check_at"]),
                    firstSyncCompletedAt: Self.date($0["first_sync_completed_at"])
                )
            }
        }
    }

    /// Raises the reader level before any row takes the API's shape, so an
    /// older build refuses the archive instead of syncing it over IMAP (D-591
    /// item 5). The account's IMAP queue is dropped: the API lists everything
    /// again by ID, so nothing in it is lost.
    public func beginGmailSync(_ account: AccountID) async throws {
        try await database.write { db in
            try ArchiveSchema.requireReaderLevel(ArchiveSchema.gmailAPIReaderLevel, db)
        }
        try await database.write { db in
            try db.execute(sql: "INSERT INTO gmail_sync_state (account_id) VALUES (?) ON CONFLICT DO NOTHING", arguments: [account.rawValue])
            try db.execute(sql: """
                DELETE FROM download_queue WHERE folder_id IN (SELECT id FROM folders WHERE account_id = ?)
                """, arguments: [account.rawValue])
        }
    }

    public func sortGmailListing(_ account: AccountID, ids: [UInt64], at: Date) async throws -> GmailListingSort {
        let now = Int(at.timeIntervalSince1970)
        return try await database.write { db in
            let allMail = try Self.allMail(db, account: account).id
            var sort = GmailListingSort()
            for id in ids {
                let gmailID = Int64(bitPattern: id)
                if let message = try Int64.fetchOne(db, sql: """
                    SELECT id FROM messages WHERE account_id = ? AND gmail_msgid = ? ORDER BY id LIMIT 1
                    """, arguments: [account.rawValue, gmailID]) {
                    // Archived already: its All Mail copy is the API's from now on, with no UID.
                    let copy = try Row.fetchOne(db, sql: """
                        SELECT uid, removed_from_server_at FROM message_folders WHERE message_id = ? AND folder_id = ?
                        """, arguments: [message, allMail])
                    let alreadyAdopted = copy != nil && (copy?["uid"] as Int64?) == nil && (copy?["removed_from_server_at"] as Int64?) == nil
                    try db.execute(sql: """
                        INSERT INTO message_folders (message_id, folder_id, last_seen_at) VALUES (?, ?, ?)
                        ON CONFLICT (message_id, folder_id) DO UPDATE SET
                            uid_validity = NULL, uid = NULL, last_seen_at = excluded.last_seen_at, removed_from_server_at = NULL
                        """, arguments: [message, allMail, now])
                    // The server has it: an imported copy counts as synced from here on (D-562).
                    try db.execute(sql: "UPDATE messages SET origin = 'synced', import_batch_id = NULL WHERE id = ? AND origin = 'imported'",
                                   arguments: [message])
                    try SourceStates.reclassify(db, messageID: message, at: now)
                    if alreadyAdopted { sort.known += 1 } else { sort.adopted += 1 }
                } else if try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM gmail_queue WHERE account_id = ? AND gmail_msgid = ?)
                        OR EXISTS (SELECT 1 FROM tombstones WHERE account_id = ? AND gmail_msgid = ?)
                    """, arguments: [account.rawValue, gmailID, account.rawValue, gmailID]) ?? false {
                    sort.known += 1
                } else {
                    sort.new.append(id)
                }
            }
            return sort
        }
    }

    @discardableResult
    public func enqueueGmail(_ account: AccountID, _ messages: [GmailQueuedMessage]) async throws -> Int {
        let now = Self.now()
        return try await database.write { db in
            var added = 0
            for message in messages {
                try db.execute(sql: """
                    INSERT INTO gmail_queue (account_id, gmail_msgid, gmail_thrid, size, internal_date, priority, queued_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                    """, arguments: [
                        account.rawValue, Int64(bitPattern: message.gmailID), message.threadID.map { Int64(bitPattern: $0) },
                        message.size, message.internalDate.map { Int($0.timeIntervalSince1970) }, message.priority, now,
                    ])
                added += db.changesCount
            }
            return added
        }
    }

    public func nextGmailDownloads(_ account: AccountID, runID: String, maxMessages: Int, maxBytes: Int) async throws -> [GmailQueuedMessage] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT gmail_msgid, gmail_thrid, size, internal_date, priority FROM gmail_queue
                WHERE account_id = ? AND state = 'queued' AND last_run_id IS NOT ?
                ORDER BY priority, internal_date, gmail_msgid LIMIT ?
                """, arguments: [account.rawValue, runID, max(1, maxMessages)])
            var batch: [GmailQueuedMessage] = []
            var bytes = 0
            for row in rows {
                let size: Int = row["size"]
                // The byte cap, but never an empty batch.
                if !batch.isEmpty, bytes + size > maxBytes { break }
                bytes += size
                batch.append(GmailQueuedMessage(
                    gmailID: UInt64(bitPattern: row["gmail_msgid"]),
                    threadID: (row["gmail_thrid"] as Int64?).map { UInt64(bitPattern: $0) },
                    size: size,
                    internalDate: Self.date(row["internal_date"]),
                    priority: row["priority"]
                ))
            }
            return batch
        }
    }

    public func gmailVanishedBeforeDownload(_ account: AccountID, ids: [UInt64]) async throws {
        try await database.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM gmail_queue WHERE account_id = ? AND gmail_msgid = ?",
                               arguments: [account.rawValue, Int64(bitPattern: id)])
            }
        }
    }

    public func recordGmailFailedAttempt(_ account: AccountID, runID: String, ids: [UInt64], threshold: Int) async throws -> Set<UInt64> {
        let now = Self.now()
        return try await database.write { db in
            var recorded: Set<UInt64> = []
            for id in ids {
                let arguments: StatementArguments = [account.rawValue, Int64(bitPattern: id)]
                // Once per run: a reconnect within a run is not a second attempt (D-115).
                try db.execute(sql: """
                    UPDATE gmail_queue SET attempts = attempts + 1, last_run_id = ?,
                        first_failed_at = coalesce(first_failed_at, ?), last_failed_at = ?
                    WHERE account_id = ? AND gmail_msgid = ? AND state = 'queued' AND last_run_id IS NOT ?
                    """, arguments: [runID, now, now] + arguments + [runID])
                try db.execute(sql: """
                    UPDATE gmail_queue SET state = 'unfetchable', recorded_at = ?
                    WHERE account_id = ? AND gmail_msgid = ? AND state = 'queued' AND attempts >= ?
                    """, arguments: [now] + arguments + [threshold])
                if db.changesCount > 0 { recorded.insert(id) }
            }
            return recorded
        }
    }

    public func gmailListingCompleted(_ account: AccountID, historyID: UInt64, at: Date) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO gmail_sync_state (account_id, history_id, full_listing_completed_at, last_full_check_at, last_listed_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (account_id) DO UPDATE SET history_id = excluded.history_id,
                    full_listing_completed_at = excluded.full_listing_completed_at, last_full_check_at = excluded.last_full_check_at,
                    last_listed_at = excluded.last_listed_at
                """, arguments: [account.rawValue, Int64(bitPattern: historyID), Int(at.timeIntervalSince1970), Int(at.timeIntervalSince1970),
                                 Int(at.timeIntervalSince1970)])
        }
        try await gmailQueueChecked(account, at: at)
    }

    public func gmailQueueChecked(_ account: AccountID, at: Date) async throws {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE gmail_sync_state SET first_sync_completed_at = ?
                WHERE account_id = ? AND first_sync_completed_at IS NULL AND full_listing_completed_at IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM gmail_queue WHERE account_id = ? AND state = 'queued')
                """, arguments: [Int(at.timeIntervalSince1970), account.rawValue, account.rawValue])
        }
    }

    // MARK: - Labels and changes (brief steps 4 and 5)

    public func recordGmailLabels(_ account: AccountID, _ labels: [GmailLabelName]) async throws {
        try await database.write { db in
            for label in labels {
                let byID = try Row.fetchOne(db, sql: """
                    SELECT id, name FROM folders WHERE account_id = ? AND kind = 'label' AND provider_id = ?
                    """, arguments: [account.rawValue, label.id])
                let byName = try Int64.fetchOne(db, sql: """
                    SELECT id FROM folders WHERE account_id = ? AND kind = 'label' AND name = ?
                    """, arguments: [account.rawValue, label.name])
                if let byID {
                    let folder: Int64 = byID["id"]
                    guard (byID["name"] as String) != label.name else { continue }
                    // Renamed in Gmail (D-595). A row already holding the new name (IMAP's,
                    // or an earlier label) is merged into this one first.
                    if let other = byName, other != folder {
                        try db.execute(sql: """
                            INSERT INTO message_folders (message_id, folder_id, last_seen_at, removed_from_server_at)
                            SELECT message_id, ?, last_seen_at, removed_from_server_at FROM message_folders WHERE folder_id = ?
                            ON CONFLICT (message_id, folder_id) DO NOTHING
                            """, arguments: [folder, other])
                        try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [other])
                    }
                    try db.execute(sql: "UPDATE folders SET name = ? WHERE id = ?", arguments: [label.name, folder])
                } else if let byName {
                    // A label IMAP sync recorded by name: from now on it is known by its ID.
                    try db.execute(sql: "UPDATE folders SET provider_id = ? WHERE id = ?", arguments: [label.id, byName])
                } else {
                    try db.execute(sql: "INSERT INTO folders (account_id, name, kind, provider_id) VALUES (?, ?, 'label', ?)",
                                   arguments: [account.rawValue, label.name, label.id])
                }
            }
        }
    }

    @discardableResult
    public func applyGmailChanges(_ account: AccountID, _ changes: [GmailCopyChange], at: Date) async throws -> Int {
        let now = Int(at.timeIntervalSince1970)
        return try await database.write { db in
            let allMail = try Self.allMail(db, account: account).id
            var changed = 0
            for change in changes where !change.isEmpty {
                guard let message = try Self.message(db, account: account, gmailID: change.gmailID) else { continue }
                var touched = false
                for name in change.addLabels {
                    let label = try Importer.folderID(db, account: account.rawValue, name: name, kind: "label")
                    try db.execute(sql: """
                        INSERT INTO message_folders (message_id, folder_id, last_seen_at) VALUES (?, ?, ?)
                        ON CONFLICT (message_id, folder_id) DO UPDATE SET removed_from_server_at = NULL, last_seen_at = excluded.last_seen_at
                        WHERE message_folders.removed_from_server_at IS NOT NULL
                        """, arguments: [message, label, now])
                    touched = touched || db.changesCount > 0
                }
                for name in change.removeLabels {
                    try db.execute(sql: """
                        UPDATE message_folders SET removed_from_server_at = ?
                        WHERE message_id = ? AND removed_from_server_at IS NULL
                            AND folder_id = (SELECT id FROM folders WHERE account_id = ? AND kind = 'label' AND name = ?)
                        """, arguments: [now, message, account.rawValue, name])
                    touched = touched || db.changesCount > 0
                }
                if !change.addFlags.isEmpty || !change.removeFlags.isEmpty,
                   let current = try String.fetchOne(db, sql: "SELECT flags FROM message_folders WHERE message_id = ? AND folder_id = ?",
                                                     arguments: [message, allMail]) {
                    var flags = Set(current.split(separator: " ").map(String.init))
                    flags.formUnion(change.addFlags)
                    flags.subtract(change.removeFlags)
                    let text = Importer.flagText(Array(flags))
                    if text != current {
                        try db.execute(sql: "UPDATE message_folders SET flags = ? WHERE message_id = ? AND folder_id = ?",
                                       arguments: [text, message, allMail])
                        touched = true
                    }
                }
                if touched { changed += 1 }
            }
            return changed
        }
    }

    public func gmailArchivedIDs(_ account: AccountID) async throws -> Set<UInt64> {
        try await database.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT m.gmail_msgid FROM messages m
                JOIN message_folders mf ON mf.message_id = m.id JOIN folders f ON f.id = mf.folder_id
                WHERE m.account_id = ? AND m.gmail_msgid IS NOT NULL AND f.account_id = m.account_id
                  AND f.special_use = '\\all' AND mf.removed_from_server_at IS NULL
                """, arguments: [account.rawValue]).map { UInt64(bitPattern: $0) })
        }
    }

    @discardableResult
    public func setGmailSourceStates(_ account: AccountID, ids: [UInt64], _ state: SourceState, at: Date) async throws -> Int {
        let now = Int(at.timeIntervalSince1970)
        return try await database.write { db in
            let allMail = try Self.allMail(db, account: account).id
            var changed = 0
            for id in ids {
                guard let message = try Self.message(db, account: account, gmailID: id) else { continue }
                if state == .present {
                    try db.execute(sql: """
                        INSERT INTO message_folders (message_id, folder_id, last_seen_at) VALUES (?, ?, ?)
                        ON CONFLICT (message_id, folder_id) DO UPDATE SET uid_validity = NULL, uid = NULL,
                            removed_from_server_at = NULL, last_seen_at = excluded.last_seen_at
                        """, arguments: [message, allMail, now])
                    if try SourceStates.reclassify(db, messageID: message, at: now) != nil { changed += 1 }
                } else {
                    try db.execute(sql: """
                        UPDATE message_folders SET removed_from_server_at = ? WHERE message_id = ? AND folder_id = ? AND removed_from_server_at IS NULL
                        """, arguments: [now, message, allMail])
                    let before = try String.fetchOne(db, sql: "SELECT source_state FROM messages WHERE id = ?", arguments: [message])
                    if before != state.rawValue {
                        try SourceStates.set(db, messageID: message, state, at: now)
                        changed += 1
                    }
                }
            }
            return changed
        }
    }

    public func gmailHistoryRead(_ account: AccountID, historyID: UInt64, at: Date) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE gmail_sync_state SET history_id = ?, last_listed_at = ? WHERE account_id = ?",
                           arguments: [Int64(bitPattern: historyID), Int(at.timeIntervalSince1970), account.rawValue])
        }
    }

    public func gmailFullChecked(_ account: AccountID, at: Date) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE gmail_sync_state SET last_full_check_at = ?, last_listed_at = ? WHERE account_id = ?",
                           arguments: [Int(at.timeIntervalSince1970), Int(at.timeIntervalSince1970), account.rawValue])
        }
    }

    /// The archived message with this Gmail ID, synced or imported.
    static func message(_ db: Database, account: AccountID, gmailID: UInt64) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT id FROM messages WHERE account_id = ? AND gmail_msgid = ? ORDER BY id LIMIT 1",
                           arguments: [account.rawValue, Int64(bitPattern: gmailID)])
    }

    /// The account's Gmail API state row, if it syncs through the API. Status,
    /// coverage and the deletion check read it instead of IMAP's per-folder state.
    /// Nil too when the archive predates `v7`: a read-only open (status, the
    /// app's reader) never migrates, so an archive a newer build has not yet
    /// written to has no Gmail API tables, and no account in it syncs through the API.
    static func gmailStateRow(_ db: Database, account: AccountID) throws -> Row? {
        guard try hasGmailAPITables(db) else { return nil }
        return try Row.fetchOne(db, sql: "SELECT * FROM gmail_sync_state WHERE account_id = ?", arguments: [account.rawValue])
    }

    /// Whether `v7` has run on this archive.
    static func hasGmailAPITables(_ db: Database) throws -> Bool {
        try db.tableExists("gmail_sync_state")
    }

    /// Queued and unfetchable messages in both queues, as one table for status
    /// and coverage. IMAP's queue alone on an archive that predates `v7`.
    static func bothQueues(_ db: Database) throws -> String {
        let imap = "SELECT q.state, q.size, q.internal_date FROM download_queue q JOIN folders f ON f.id = q.folder_id WHERE f.account_id = :account"
        guard try hasGmailAPITables(db) else { return "(\(imap))" }
        return "(\(imap) UNION ALL SELECT state, size, internal_date FROM gmail_queue WHERE account_id = :account)"
    }

    static func date(_ seconds: Int64?) -> Date? {
        seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
