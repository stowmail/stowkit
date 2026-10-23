import Foundation
import GRDB
import StowCore

/// Sync writes straight into the archive through this (brief step 4): it is
/// the `RawMessageSink` that imports each downloaded message, and the
/// `SyncStateStore` that keeps the download queue and folder state in the
/// archive's database (D-027).
///
/// Each downloaded message is imported and taken off the queue in the same
/// transaction, so "durable before the queue moves on" holds by construction:
/// after a crash a message is either archived and gone from the queue, or
/// still queued and downloaded again (the import is idempotent).
public final class ArchiveSyncStore: RawMessageSink, SyncStateStore, Sendable {
    public let archive: Archive
    let importer: Importer

    public init(archive: Archive, importer: Importer? = nil) {
        self.archive = archive
        self.importer = importer ?? Importer(archive: archive)
    }

    var database: DatabasePool { archive.database }

    // MARK: - RawMessageSink

    public func write(_ message: RawMessage) async throws {
        let key = message.key
        let restoring = try await database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT q.restore FROM download_queue q JOIN folders f ON f.id = q.folder_id
                WHERE f.account_id = ? AND f.kind = 'folder' AND f.name = ? AND q.uid_validity = ? AND q.uid = ?
                """, arguments: [key.accountID.rawValue, key.folder, Int64(key.uidValidity), Int64(key.uid)]) ?? false
        }
        _ = try importer.importMessage(message, restoring: restoring) { db, _ in
            let folder = try Self.folderID(db, account: key.accountID, name: key.folder)
            try db.execute(sql: "DELETE FROM download_queue WHERE folder_id = ? AND uid_validity = ? AND uid = ?",
                           arguments: [folder, Int64(key.uidValidity), Int64(key.uid)])
        }
    }

    /// Every write is committed by its own transaction before it returns.
    public func flush() async throws {}

    // MARK: - Folders

    public func recordFolders(_ account: AccountID, _ folders: [SyncFolder]) async throws {
        try await database.write { db in
            for folder in folders {
                try db.execute(sql: """
                    INSERT INTO folders (account_id, name, kind, delimiter, special_use, is_selectable, skipped_reason)
                    VALUES (?, ?, 'folder', ?, ?, ?, ?)
                    ON CONFLICT (account_id, kind, name) DO UPDATE SET delimiter = excluded.delimiter,
                        special_use = excluded.special_use, is_selectable = excluded.is_selectable,
                        skipped_reason = excluded.skipped_reason
                    """, arguments: [account.rawValue, folder.name, folder.delimiter, folder.specialUse, folder.isSelectable,
                                     folder.skippedReason])
            }
            // Folders no longer listed: deleted or renamed on the server.
            let listed = Set(folders.map(\.name))
            let known = try Row.fetchAll(db, sql: "SELECT id, name FROM folders WHERE account_id = ? AND kind = 'folder'",
                                         arguments: [account.rawValue])
            for row in known where !listed.contains(row["name"]) {
                try db.execute(sql: "UPDATE folders SET skipped_reason = 'no longer on the server' WHERE id = ?",
                               arguments: [row["id"] as Int64])
            }
        }
    }

    public func folderState(_ account: AccountID, folder: String) async throws -> FolderSyncState? {
        try await database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT s.* FROM sync_state s JOIN folders f ON f.id = s.folder_id
                WHERE f.account_id = ? AND f.kind = 'folder' AND f.name = ?
                """, arguments: [account.rawValue, folder]).map(Self.state)
        }
    }

    public func syncedFolders(_ account: AccountID) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT f.name FROM sync_state s JOIN folders f ON f.id = s.folder_id WHERE f.account_id = ? ORDER BY f.name
                """, arguments: [account.rawValue])
        }
    }

    public func beginFolder(_ account: AccountID, folder: String, uidValidity: UInt32, exists: Int) async throws -> UInt32? {
        try await database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            let now = Self.now()
            let old = try Int64.fetchOne(db, sql: "SELECT uid_validity FROM sync_state WHERE folder_id = ?", arguments: [folderID])
            try db.execute(sql: "UPDATE folders SET uid_validity = ? WHERE id = ?", arguments: [Int64(uidValidity), folderID])
            guard let old else {
                try db.execute(sql: """
                    INSERT INTO sync_state (folder_id, uid_validity, server_exists, status) VALUES (?, ?, ?, 'syncing')
                    """, arguments: [folderID, Int64(uidValidity), exists])
                return nil
            }
            guard old != Int64(uidValidity) else {
                try db.execute(sql: "UPDATE sync_state SET server_exists = ?, status = 'syncing' WHERE folder_id = ?",
                               arguments: [exists, folderID])
                return nil
            }
            // Every UID changed meaning: forget the old queue and list again from the start.
            try db.execute(sql: "DELETE FROM download_queue WHERE folder_id = ? AND uid_validity != ?",
                           arguments: [folderID, Int64(uidValidity)])
            try db.execute(sql: """
                UPDATE sync_state SET uid_validity = ?, listed_through_uid = 0, highest_modseq = NULL, last_sync_at = NULL,
                    first_sync_completed_at = NULL, server_exists = ?, status = 'syncing'
                WHERE folder_id = ?
                """, arguments: [Int64(uidValidity), exists, folderID])
            try Self.event(db, account: account, folderID: folderID, kind: "uidvalidity_changed",
                           old: String(old), new: String(uidValidity), at: now)
            return UInt32(truncatingIfNeeded: old)
        }
    }

    // MARK: - Queue

    @discardableResult
    public func enqueue(_ account: AccountID, folder: String, uidValidity: UInt32, messages: [QueuedMessage], listedThrough: UInt32) async throws -> Int {
        try await database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            let now = Self.now()
            // Once the folder has been walked in full, anything new has just arrived:
            // personal mail of that kind goes ahead of the backlog (D-043).
            let walked = try Bool.fetchOne(db, sql: "SELECT last_sync_at IS NOT NULL FROM sync_state WHERE folder_id = ?",
                                           arguments: [folderID]) ?? false
            var queued = 0
            for message in messages {
                let location: StatementArguments = [folderID, Int64(uidValidity), Int64(message.uid)]
                // Archived at this place already (for example imported from the development store).
                if try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM message_folders WHERE folder_id = ? AND uid_validity = ? AND uid = ?)
                    """, arguments: location) == true { continue }
                // Removed from the archive by the user: never downloaded again (D-033).
                if try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM tombstone_copies WHERE folder_id = ? AND uid_validity = ? AND uid = ?)
                    """, arguments: location) == true { continue }
                if let gmailID = message.gmailMessageID.map({ Int64(bitPattern: $0) }) {
                    if let tombstone = try Int64.fetchOne(db, sql: "SELECT id FROM tombstones WHERE account_id = ? AND gmail_msgid = ?",
                                                          arguments: [account.rawValue, gmailID]) {
                        try db.execute(sql: """
                            INSERT INTO tombstone_copies (tombstone_id, folder_id, uid_validity, uid) VALUES (?, ?, ?, ?)
                            ON CONFLICT DO NOTHING
                            """, arguments: [tombstone] + location)
                        continue
                    }
                    // Gmail's message ID is permanent: a message already archived under
                    // another UID (after a UIDVALIDITY change, or back from the Bin)
                    // only needs its copy moved, not a second download (D-038).
                    if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM messages WHERE account_id = ? AND gmail_msgid = ?",
                                                         arguments: [account.rawValue, gmailID]) {
                        try db.execute(sql: """
                            INSERT INTO message_folders (message_id, folder_id, uid_validity, uid, last_seen_at) VALUES (?, ?, ?, ?, ?)
                            ON CONFLICT (message_id, folder_id) DO UPDATE SET uid_validity = excluded.uid_validity,
                                uid = excluded.uid, last_seen_at = excluded.last_seen_at, removed_from_server_at = NULL
                            """, arguments: [existing] + location + [now])
                        try SourceStates.reclassify(db, messageID: existing, at: now)
                        continue
                    }
                }
                try db.execute(sql: """
                    INSERT INTO download_queue (folder_id, uid_validity, uid, size, internal_date, priority, gmail_msgid, queued_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                    """, arguments: location + [message.size, message.internalDate.map { Int($0.timeIntervalSince1970) },
                                                walked && message.priority == 0 ? QueuedMessage.newArrival : message.priority,
                                                message.gmailMessageID.map { Int64(bitPattern: $0) }, now])
                queued += db.changesCount
            }
            try db.execute(sql: "UPDATE sync_state SET listed_through_uid = max(listed_through_uid, ?) WHERE folder_id = ?",
                           arguments: [Int64(listedThrough), folderID])
            return queued
        }
    }

    public func nextDownloads(_ account: AccountID, runID: String, maxMessages: Int, maxBytes: Int) async throws -> [QueuedMessage] {
        try await database.read { db in
            let eligible = """
                FROM download_queue q JOIN folders f ON f.id = q.folder_id
                JOIN sync_state s ON s.folder_id = q.folder_id AND s.uid_validity = q.uid_validity
                WHERE f.account_id = ? AND q.state = 'queued' AND coalesce(q.last_run_id, '') != ?
                """
            guard let first = try Row.fetchOne(db, sql: "SELECT q.folder_id, q.priority \(eligible) ORDER BY q.priority, q.folder_id, q.uid LIMIT 1",
                                               arguments: [account.rawValue, runID])
            else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT q.*, f.name \(eligible) AND q.folder_id = ? AND q.priority = ? ORDER BY q.uid LIMIT ?
                """, arguments: [account.rawValue, runID, first["folder_id"] as Int64, first["priority"] as Int, max(1, maxMessages)])
            var batch: [QueuedMessage] = []
            var bytes = 0
            for row in rows {
                let message = Self.queued(row)
                if !batch.isEmpty, bytes + message.size > maxBytes { break }
                batch.append(message)
                bytes += message.size
            }
            return batch
        }
    }

    public func downloaded(_ account: AccountID, folder: String, uidValidity: UInt32, uids: [UInt32]) async throws {
        try dequeue(account, folder: folder, uidValidity: uidValidity, uids: uids)
    }

    public func vanishedBeforeDownload(_ account: AccountID, folder: String, uidValidity: UInt32, uids: [UInt32]) async throws {
        try dequeue(account, folder: folder, uidValidity: uidValidity, uids: uids)
    }

    private func dequeue(_ account: AccountID, folder: String, uidValidity: UInt32, uids: [UInt32]) throws {
        guard !uids.isEmpty else { return }
        try database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            for uid in uids {
                try db.execute(sql: "DELETE FROM download_queue WHERE folder_id = ? AND uid_validity = ? AND uid = ?",
                               arguments: [folderID, Int64(uidValidity), Int64(uid)])
            }
        }
    }

    public func recordFailedAttempt(_ account: AccountID, folder: String, uidValidity: UInt32, runID: String,
                                    failed: [FailedDownload], threshold: Int) async throws -> Set<UInt32> {
        try await database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            let now = Self.now()
            var recorded: Set<UInt32> = []
            for failure in failed {
                let location: StatementArguments = [folderID, Int64(uidValidity), Int64(failure.uid)]
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT attempts, last_run_id, state FROM download_queue WHERE folder_id = ? AND uid_validity = ? AND uid = ?
                    """, arguments: location) else { continue }
                let lastRun: String? = row["last_run_id"]
                let attempts = (row["attempts"] as Int) + (lastRun == runID ? 0 : 1)
                try db.execute(sql: """
                    UPDATE download_queue SET attempts = ?, last_run_id = ?, flags = ?,
                        first_failed_at = coalesce(first_failed_at, ?), last_failed_at = ?
                    WHERE folder_id = ? AND uid_validity = ? AND uid = ?
                    """, arguments: [attempts, runID, Importer.flagText(failure.flags), now, now] + location)
                if attempts >= max(1, threshold) {
                    if row["state"] as String != "unfetchable" {
                        try db.execute(sql: """
                            UPDATE download_queue SET state = 'unfetchable', recorded_at = ? WHERE folder_id = ? AND uid_validity = ? AND uid = ?
                            """, arguments: [now] + location)
                        try Self.event(db, account: account, folderID: folderID, kind: "unfetchable_recorded",
                                       old: nil, new: String(failure.uid), at: now)
                    }
                    recorded.insert(failure.uid)
                }
            }
            return recorded
        }
    }

    public func queueTotals(_ account: AccountID) async throws -> QueueTotals {
        try await database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT coalesce(sum(q.state = 'queued'), 0) AS queued,
                       coalesce(sum(CASE WHEN q.state = 'queued' THEN q.size ELSE 0 END), 0) AS bytes,
                       coalesce(sum(q.state = 'unfetchable'), 0) AS unfetchable
                FROM download_queue q JOIN folders f ON f.id = q.folder_id WHERE f.account_id = ?
                """, arguments: [account.rawValue])!
            return QueueTotals(queued: row["queued"], queuedBytes: row["bytes"], unfetchable: row["unfetchable"])
        }
    }

    public func queuedUIDs(_ account: AccountID, folder: String, uidValidity: UInt32) async throws -> [UInt32] {
        try await database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT q.uid FROM download_queue q JOIN folders f ON f.id = q.folder_id
                WHERE f.account_id = ? AND f.kind = 'folder' AND f.name = ? AND q.uid_validity = ? ORDER BY q.uid
                """, arguments: [account.rawValue, folder, Int64(uidValidity)]).map { UInt32(truncatingIfNeeded: $0) }
        }
    }

    public func folderWalked(_ account: AccountID, folder: String, uidValidity: UInt32, at date: Date) async throws {
        try await database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            let at = Int(date.timeIntervalSince1970)
            try db.execute(sql: "UPDATE sync_state SET last_sync_at = ?, status = 'idle', last_error = NULL WHERE folder_id = ?",
                           arguments: [at, folderID])
            let queued = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM download_queue WHERE folder_id = ? AND uid_validity = ? AND state = 'queued')
                """, arguments: [folderID, Int64(uidValidity)]) ?? false
            guard !queued else { return }
            try db.execute(sql: "UPDATE sync_state SET first_sync_completed_at = coalesce(first_sync_completed_at, ?) WHERE folder_id = ?",
                           arguments: [at, folderID])
            // After a UIDVALIDITY change the new walk has moved every copy it
            // found; copies still at the old value were not found again.
            let stale = try Int64.fetchAll(db, sql: """
                SELECT message_id FROM message_folders
                WHERE folder_id = ? AND uid_validity != ? AND removed_from_server_at IS NULL
                """, arguments: [folderID, Int64(uidValidity)])
            guard !stale.isEmpty else { return }
            try db.execute(sql: """
                UPDATE message_folders SET removed_from_server_at = ?
                WHERE folder_id = ? AND uid_validity != ? AND removed_from_server_at IS NULL
                """, arguments: [at, folderID, Int64(uidValidity)])
            for message in stale where try Self.presence(db, messageID: message) == .none {
                try SourceStates.set(db, messageID: message, .gone, at: at)
            }
        }
    }

    // MARK: - Changes at the source

    public func storedUIDs(_ account: AccountID, folder: String, uidValidity: UInt32) async throws -> [UInt32] {
        try await database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT mf.uid FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                WHERE f.account_id = ? AND f.kind = 'folder' AND f.name = ? AND mf.uid_validity = ?
                    AND mf.removed_from_server_at IS NULL AND mf.uid IS NOT NULL
                ORDER BY mf.uid
                """, arguments: [account.rawValue, folder, Int64(uidValidity)]).map { UInt32(truncatingIfNeeded: $0) }
        }
    }

    public func applyCopyStates(_ account: AccountID, folder: String, uidValidity: UInt32, _ states: [CopyState], at date: Date) async throws {
        guard !states.isEmpty else { return }
        try await database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            let at = Int(date.timeIntervalSince1970)
            for state in states {
                guard let messageID = try Int64.fetchOne(db, sql: """
                    SELECT message_id FROM message_folders WHERE folder_id = ? AND uid_validity = ? AND uid = ?
                    """, arguments: [folderID, Int64(uidValidity), Int64(state.uid)]) else { continue }
                try db.execute(sql: "UPDATE message_folders SET flags = ?, last_seen_at = ? WHERE message_id = ? AND folder_id = ?",
                               arguments: [Importer.flagText(state.flags), at, messageID, folderID])
                guard let labels = state.labels else { continue }
                let wanted = Set(labels)
                let current = try Row.fetchAll(db, sql: """
                    SELECT mf.folder_id, f.name FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                    WHERE mf.message_id = ? AND f.kind = 'label' AND mf.removed_from_server_at IS NULL
                    """, arguments: [messageID])
                for row in current where !wanted.contains(row["name"]) {
                    try db.execute(sql: "UPDATE message_folders SET removed_from_server_at = ? WHERE message_id = ? AND folder_id = ?",
                                   arguments: [at, messageID, row["folder_id"] as Int64])
                }
                let have = Set(current.map { $0["name"] as String })
                for label in wanted.subtracting(have) {
                    let labelID = try Importer.folderID(db, account: account.rawValue, name: label, kind: "label")
                    try db.execute(sql: """
                        INSERT INTO message_folders (message_id, folder_id, last_seen_at) VALUES (?, ?, ?)
                        ON CONFLICT (message_id, folder_id) DO UPDATE SET removed_from_server_at = NULL, last_seen_at = excluded.last_seen_at
                        """, arguments: [messageID, labelID, at])
                }
            }
        }
    }

    public func markRemovedFromServer(_ account: AccountID, folder: String, uidValidity: UInt32, uids: [UInt32], at date: Date) async throws -> [VanishedMessage] {
        guard !uids.isEmpty else { return [] }
        return try await database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            let at = Int(date.timeIntervalSince1970)
            var messages: [Int64] = []
            for uid in uids {
                let location: StatementArguments = [folderID, Int64(uidValidity), Int64(uid)]
                guard let message = try Int64.fetchOne(db, sql: """
                    SELECT message_id FROM message_folders
                    WHERE folder_id = ? AND uid_validity = ? AND uid = ? AND removed_from_server_at IS NULL
                    """, arguments: location) else { continue }
                try db.execute(sql: """
                    UPDATE message_folders SET removed_from_server_at = ? WHERE folder_id = ? AND uid_validity = ? AND uid = ?
                    """, arguments: [at] + location)
                messages.append(message)
            }
            var vanished: [VanishedMessage] = []
            for message in Set(messages).sorted() {
                switch try Self.presence(db, messageID: message) {
                case .elsewhere: try SourceStates.set(db, messageID: message, .present, at: at)
                case .trashOnly: try SourceStates.set(db, messageID: message, .trashed, at: at)
                case .none:
                    let row = try Row.fetchOne(db, sql: "SELECT gmail_msgid, rfc822_message_id FROM messages WHERE id = ?",
                                               arguments: [message])
                    vanished.append(VanishedMessage(
                        messageID: message,
                        gmailMessageID: (row?["gmail_msgid"] as Int64?).map { UInt64(bitPattern: $0) },
                        rfc822MessageID: row?["rfc822_message_id"]))
                }
            }
            return vanished
        }
    }

    public func setSourceStates(_ account: AccountID, _ states: [Int64: SourceState], at date: Date) async throws {
        guard !states.isEmpty else { return }
        try await database.write { db in
            for (message, state) in states {
                try db.execute(sql: """
                    UPDATE messages SET source_state = ?, source_state_at = ? WHERE id = ? AND account_id = ? AND source_state != ?
                    """, arguments: [state.rawValue, Int(date.timeIntervalSince1970), message, account.rawValue, state.rawValue])
            }
        }
    }

    public func folderChecked(_ account: AccountID, folder: String, uidValidity: UInt32, highestModSeq: UInt64?, fullCheck: Bool, at date: Date) async throws {
        try await database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            try db.execute(sql: """
                UPDATE sync_state SET highest_modseq = coalesce(?, highest_modseq),
                    last_full_sync_at = CASE WHEN ? THEN ? ELSE last_full_sync_at END
                WHERE folder_id = ? AND uid_validity = ?
                """, arguments: [highestModSeq.map { Int64(bitPattern: $0) }, fullCheck, Int(date.timeIntervalSince1970),
                                 folderID, Int64(uidValidity)])
        }
    }

    // MARK: - Byte budget

    public func bytesDownloaded(_ account: AccountID, since date: Date) async throws -> Int64 {
        try await database.read { db in
            try Int64.fetchOne(db, sql: "SELECT coalesce(sum(bytes), 0) FROM byte_budget WHERE account_id = ? AND at > ?",
                               arguments: [account.rawValue, Int(date.timeIntervalSince1970)]) ?? 0
        }
    }

    public func recordDownload(_ account: AccountID, bytes: Int64, at date: Date) async throws {
        guard bytes > 0 else { return }
        try await database.write { db in
            let at = Int(date.timeIntervalSince1970)
            try db.execute(sql: "INSERT INTO byte_budget (account_id, at, bytes) VALUES (?, ?, ?)", arguments: [account.rawValue, at, bytes])
            // Only the last day counts; keep two for status.
            try db.execute(sql: "DELETE FROM byte_budget WHERE account_id = ? AND at < ?", arguments: [account.rawValue, at - 2 * 86_400])
        }
    }

    // MARK: - Status

    public func recordEvent(_ account: AccountID, folder: String?, kind: String, old: String?, new: String?, at date: Date) async throws {
        try await database.write { db in
            let folderID = try folder.map { try Self.folderID(db, account: account, name: $0) }
            try Self.event(db, account: account, folderID: folderID, kind: kind, old: old, new: new, at: Int(date.timeIntervalSince1970))
        }
    }

    public func setFolderError(_ account: AccountID, folder: String, error: String?) async throws {
        try await database.write { db in
            let folderID = try Self.folderID(db, account: account, name: folder)
            try db.execute(sql: "UPDATE sync_state SET status = ?, last_error = ? WHERE folder_id = ?",
                           arguments: [error == nil ? "idle" : "error", error.map(Redact.scrub), folderID])
        }
    }

    // MARK: - Helpers

    static func now() -> Int { Int(Date().timeIntervalSince1970) }

    static func folderID(_ db: Database, account: AccountID, name: String) throws -> Int64 {
        try Importer.folderID(db, account: account.rawValue, name: name, kind: "folder")
    }

    static func event(_ db: Database, account: AccountID, folderID: Int64?, kind: String, old: String?, new: String?, at: Int) throws {
        try db.execute(sql: """
            INSERT INTO sync_events (account_id, folder_id, kind, old_value, new_value, at) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [account.rawValue, folderID, kind, old, new, at])
    }

    enum Presence {
        /// Still on the server in a folder that is not a Trash folder.
        case elsewhere
        /// Only in a Trash folder (Microsoft's Deleted Items).
        case trashOnly
        case none
    }

    static func presence(_ db: Database, messageID: Int64) throws -> Presence {
        let row = try Row.fetchOne(db, sql: """
            SELECT
                coalesce(max(CASE WHEN coalesce(f.special_use, '') != '\\trash' THEN 1 ELSE 0 END), 0) AS elsewhere,
                coalesce(max(CASE WHEN f.special_use = '\\trash' THEN 1 ELSE 0 END), 0) AS trash
            FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
            WHERE mf.message_id = ? AND f.kind = 'folder' AND mf.removed_from_server_at IS NULL
            """, arguments: [messageID])
        if row?["elsewhere"] as Int? == 1 { return .elsewhere }
        if row?["trash"] as Int? == 1 { return .trashOnly }
        return .none
    }

    static func state(_ row: Row) -> FolderSyncState {
        FolderSyncState(
            uidValidity: UInt32(truncatingIfNeeded: row["uid_validity"] as Int64),
            listedThroughUID: UInt32(truncatingIfNeeded: row["listed_through_uid"] as Int64),
            highestModSeq: (row["highest_modseq"] as Int64?).map { UInt64(bitPattern: $0) },
            lastFullCheckAt: (row["last_full_sync_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            firstSyncCompletedAt: (row["first_sync_completed_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    static func queued(_ row: Row) -> QueuedMessage {
        QueuedMessage(
            folder: row["name"],
            uidValidity: UInt32(truncatingIfNeeded: row["uid_validity"] as Int64),
            uid: UInt32(truncatingIfNeeded: row["uid"] as Int64),
            size: row["size"],
            internalDate: (row["internal_date"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            priority: row["priority"],
            gmailMessageID: (row["gmail_msgid"] as Int64?).map { UInt64(bitPattern: $0) }
        )
    }
}
