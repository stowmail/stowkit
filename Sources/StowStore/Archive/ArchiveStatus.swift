import Foundation
import GRDB
import StowCore

/// One account's state for `stowmail status` (step 8): last sync, progress,
/// today's downloads, the last error in plain words, and changes at the
/// provider. Counts, dates and scrubbed error text only.
public struct AccountStatus: Sendable, Equatable {
    public var account: AccountRecord
    public var lastSyncAt: Date?
    public var lastSuccessAt: Date?
    public var lastError: String?
    public var archivedMessages = 0
    public var archivedBytes = 0
    public var queue = QueueTotals()
    /// Every synced folder has finished its first sync.
    public var firstSyncComplete = false
    public var foldersSynced = 0
    /// Folders whose last attempt failed, with the scrubbed reason.
    public var folderErrors: [String] = []
    public var bytesLast24Hours: Int64 = 0
    public var coverageDate: Date?
    /// Synced messages whose state changed at the provider; imported mail's came from its file (D-567).
    public var sourceStates: [SourceState: Int] = [:]
    public var removed = 0
    /// Attachments of this account's mail whose text waits for OCR (D-207, R10).
    /// `ArchiveStats.ocrPending` is the same count for the whole archive.
    public var ocrPending = 0
    /// Messages stored from an import that no server copy has turned synced (D-562, D-567).
    public var importedMessages = 0
    /// Imports that have not reached the end of their file, oldest first (D-564).
    public var unfinishedImports: [ImportBatch] = []

    /// Share of known messages already archived, 0 to 1.
    public var progress: Double {
        let total = archivedMessages + queue.queued + queue.unfetchable
        return total == 0 ? 0 : Double(archivedMessages) / Double(total)
    }
}

/// One synced folder's numbers, for `stowmail status --folders`: what the
/// server said it holds, against what Stow has archived, queued or recorded.
public struct FolderReport: Sendable, Equatable {
    public var name: String
    /// EXISTS from the server's last EXAMINE: its own message count.
    public var serverCount: Int?
    /// Archived copies at the current UIDVALIDITY that the server still had last time.
    public var archived = 0
    public var queued = 0
    public var unfetchable = 0
    public var firstSyncComplete = false
    public var lastSyncAt: Date?
    public var lastError: String?

    /// Whether Stow accounts for every message the server reported. A difference
    /// can be mail that arrived since the last listing, or one message stored
    /// twice in the same folder (kept once).
    public var matches: Bool {
        serverCount.map { $0 == archived + queued + unfetchable } ?? false
    }
}

public enum ArchiveStatus {
    /// Per-folder numbers for one account's synced folders, by name.
    public static func folders(_ archive: Archive, account: AccountID) throws -> [FolderReport] {
        try archive.database.read { db in
            // A Gmail account on the API has one place, All Mail, with copies that have no UID (D-591).
            if let gmail = try ArchiveSyncStore.gmailStateRow(db, account: account) {
                let allMail = try Row.fetchOne(db, sql: """
                    SELECT f.name, (SELECT count(*) FROM message_folders mf WHERE mf.folder_id = f.id AND mf.uid IS NULL
                        AND mf.removed_from_server_at IS NULL) AS archived
                    FROM folders f WHERE f.account_id = ? AND f.kind = 'folder' AND f.special_use = '\\all' ORDER BY f.id LIMIT 1
                    """, arguments: [account.rawValue])
                let queue = try Row.fetchOne(db, sql: """
                    SELECT coalesce(sum(state = 'queued'), 0) AS queued, coalesce(sum(state = 'unfetchable'), 0) AS unfetchable
                    FROM gmail_queue WHERE account_id = ?
                    """, arguments: [account.rawValue])!
                var report = FolderReport(name: allMail?["name"] ?? ArchiveSyncStore.gmailAllMailName)
                report.archived = allMail?["archived"] ?? 0
                report.queued = queue["queued"]
                report.unfetchable = queue["unfetchable"]
                report.firstSyncComplete = (gmail["first_sync_completed_at"] as Int64?) != nil
                report.lastSyncAt = ArchiveSyncStore.date(gmail["last_listed_at"])
                report.lastError = gmail["last_error"]
                return [report]
            }
            return try Row.fetchAll(db, sql: """
                SELECT f.name, s.server_exists, s.first_sync_completed_at, s.last_sync_at, s.last_error,
                    (SELECT count(*) FROM message_folders mf WHERE mf.folder_id = f.id AND mf.uid_validity = s.uid_validity
                        AND mf.removed_from_server_at IS NULL) AS archived,
                    (SELECT count(*) FROM download_queue q WHERE q.folder_id = f.id AND q.uid_validity = s.uid_validity
                        AND q.state = 'queued') AS queued,
                    (SELECT count(*) FROM download_queue q WHERE q.folder_id = f.id AND q.uid_validity = s.uid_validity
                        AND q.state = 'unfetchable') AS unfetchable
                FROM folders f JOIN sync_state s ON s.folder_id = f.id
                WHERE f.account_id = ? AND f.kind = 'folder' AND f.skipped_reason IS NULL
                ORDER BY f.name
                """, arguments: [account.rawValue]).map { row in
                var report = FolderReport(name: row["name"])
                report.serverCount = row["server_exists"]
                report.archived = row["archived"]
                report.queued = row["queued"]
                report.unfetchable = row["unfetchable"]
                report.firstSyncComplete = (row["first_sync_completed_at"] as Int64?) != nil
                report.lastSyncAt = (row["last_sync_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                report.lastError = row["last_error"]
                return report
            }
        }
    }

    public static func collect(_ archive: Archive, now: Date = Date()) throws -> [AccountStatus] {
        let records = try ArchiveAccounts(archive: archive).all()
        return try archive.database.read { db in
            try records.map { record in
                let id = record.account.id.rawValue
                var status = AccountStatus(account: record)
                let account = try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [id])
                func date(_ column: String) -> Date? {
                    (account?[column] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                }
                status.lastSyncAt = date("last_sync_at")
                status.lastSuccessAt = date("last_success_at")
                status.lastError = account?["last_error"]
                var coverage = CoverageReport(account: record.account.id)
                try Coverage.measure(db, into: &coverage)
                status.coverageDate = coverage.coverageDate
                let messages = try Row.fetchOne(db, sql: """
                    SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM messages WHERE account_id = ?
                    """, arguments: [id])!
                status.archivedMessages = messages["n"]
                status.archivedBytes = messages["bytes"]
                let queue = try Row.fetchOne(db, sql: """
                    SELECT coalesce(sum(q.state = 'queued'), 0) AS queued,
                           coalesce(sum(CASE WHEN q.state = 'queued' THEN q.size ELSE 0 END), 0) AS bytes,
                           coalesce(sum(q.state = 'unfetchable'), 0) AS unfetchable
                    FROM \(try ArchiveSyncStore.bothQueues(db)) q
                    """, arguments: ["account": id])!
                status.queue = QueueTotals(queued: queue["queued"], queuedBytes: queue["bytes"], unfetchable: queue["unfetchable"])
                let folders = try Row.fetchAll(db, sql: """
                    SELECT s.first_sync_completed_at, s.status, s.last_error FROM folders f JOIN sync_state s ON s.folder_id = f.id
                    WHERE f.account_id = ? AND f.kind = 'folder' AND f.skipped_reason IS NULL
                    """, arguments: [id])
                status.foldersSynced = folders.count
                status.firstSyncComplete = !folders.isEmpty && folders.allSatisfy { ($0["first_sync_completed_at"] as Int64?) != nil }
                if let gmail = try ArchiveSyncStore.gmailStateRow(db, account: record.account.id) {
                    // The API's one listing stands in for IMAP's folders (D-591).
                    status.foldersSynced = 1
                    status.firstSyncComplete = (gmail["first_sync_completed_at"] as Int64?) != nil
                    status.folderErrors = gmail["status"] as String == "error" ? [gmail["last_error"] as String?].compactMap { $0 } : []
                }
                status.folderErrors = folders.compactMap { $0["status"] as String == "error" ? $0["last_error"] as String? : nil }
                let origin = try ArchiveSchema.origin(db)
                status.bytesLast24Hours = try Int64.fetchOne(db, sql: """
                    SELECT coalesce(sum(bytes), 0) FROM byte_budget WHERE account_id = ? AND at > ?
                    """, arguments: [id, Int(now.timeIntervalSince1970) - 86_400]) ?? 0
                for row in try Row.fetchAll(db, sql: """
                    SELECT source_state, count(*) AS n FROM messages WHERE account_id = ? AND source_state != 'present' AND \(origin) = 'synced'
                    GROUP BY source_state
                    """, arguments: [id]) {
                    if let state = SourceState(rawValue: row["source_state"]) { status.sourceStates[state] = row["n"] }
                }
                status.removed = try Int.fetchOne(db, sql: "SELECT count(*) FROM tombstones WHERE account_id = ?", arguments: [id]) ?? 0
                status.importedMessages = try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM messages WHERE account_id = ? AND \(origin) = 'imported'
                    """, arguments: [id]) ?? 0
                status.unfinishedImports = try MboxImporter.unfinished(db, account: record.account.id)
                status.ocrPending = try Int.fetchOne(db, sql: """
                    SELECT count(DISTINCT t.id) FROM attachments t
                    JOIN message_attachments x ON x.attachment_id = t.id JOIN messages m ON m.id = x.message_id
                    WHERE m.account_id = ? AND t.text_status = 'ocr_pending'
                    """, arguments: [id]) ?? 0
                return status
            }
        }
    }
}

/// The archive's Gmail messages by Gmail ID, for comparing with the Gmail API
/// (D-593). Lists synced messages whose All Mail copy is still at Gmail;
/// imported mail has no server copy and is left out (D-567).
public struct ArchiveGmailSource: GmailMessageSource {
    public let archive: Archive
    public let account: AccountID

    public init(archive: Archive, account: AccountID) {
        self.archive = archive
        self.account = account
    }

    public func listGmailMessageIDs() async throws -> [UInt64] {
        try await archive.database.read { [account] db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT m.gmail_msgid FROM messages m
                JOIN message_folders mf ON mf.message_id = m.id JOIN folders f ON f.id = mf.folder_id
                WHERE m.account_id = ? AND m.gmail_msgid IS NOT NULL AND \(try ArchiveSchema.origin(db, "m")) = 'synced'
                  AND f.account_id = m.account_id AND f.special_use = '\\all' AND mf.removed_from_server_at IS NULL
                """, arguments: [account.rawValue]).map { UInt64(bitPattern: $0) }.sorted()
        }
    }

    public func storedGmailThreadID(_ id: UInt64) async throws -> UInt64? {
        try await archive.database.read { [account] db in
            try Int64.fetchOne(db, sql: """
                SELECT gmail_thrid FROM messages WHERE account_id = ? AND gmail_msgid = ? AND \(try ArchiveSchema.origin(db)) = 'synced' ORDER BY id LIMIT 1
                """, arguments: [account.rawValue, Int64(bitPattern: id)]).map { UInt64(bitPattern: $0) }
        }
    }

    public func readGmailMessage(_ id: UInt64) async throws -> Data {
        let found = try await archive.database.read { [account] db -> (hash: Data, state: String)? in
            try Row.fetchOne(db, sql: """
                SELECT raw_hash, raw_state FROM messages WHERE account_id = ? AND gmail_msgid = ? AND \(try ArchiveSchema.origin(db)) = 'synced' ORDER BY id LIMIT 1
                """, arguments: [account.rawValue, Int64(bitPattern: id)]).map { ($0["raw_hash"], $0["raw_state"]) }
        }
        guard let found else { throw CocoaError(.fileNoSuchFile) }
        return try archive.rawMessage(hash: found.hash, state: found.state)
    }
}

/// The archive as a `RawMessageSource`, so `StoreVerifier` can compare
/// archived messages with the server (D-121, `stowmail verify --server`).
/// Lists every archived copy still on the server, by its place there.
public struct ArchiveRawSource: RawMessageSource {
    public let archive: Archive
    public let account: AccountID

    public init(archive: Archive, account: AccountID) {
        self.archive = archive
        self.account = account
    }

    public func listKeys() async throws -> [RawMessageKey] {
        try await archive.database.read { [account] db in
            try Row.fetchAll(db, sql: """
                SELECT f.name, mf.uid_validity, mf.uid FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                WHERE f.account_id = ? AND f.kind = 'folder' AND mf.uid IS NOT NULL AND mf.removed_from_server_at IS NULL
                """, arguments: [account.rawValue]).map {
                RawMessageKey(accountID: account, folder: $0["name"],
                              uidValidity: UInt32(truncatingIfNeeded: $0["uid_validity"] as Int64),
                              uid: UInt32(truncatingIfNeeded: $0["uid"] as Int64))
            }.sorted()
        }
    }

    public func read(_ key: RawMessageKey) async throws -> RawMessage {
        let found = try await archive.database.read { [account] db -> (hash: Data, state: String, date: Int64, size: Int)? in
            try Row.fetchOne(db, sql: """
                SELECT m.raw_hash, m.raw_state, m.internal_date, m.size FROM message_folders mf
                JOIN folders f ON f.id = mf.folder_id JOIN messages m ON m.id = mf.message_id
                WHERE f.account_id = ? AND f.kind = 'folder' AND f.name = ? AND mf.uid_validity = ? AND mf.uid = ?
                """, arguments: [account.rawValue, key.folder, Int64(key.uidValidity), Int64(key.uid)])
                .map { ($0["raw_hash"], $0["raw_state"], $0["internal_date"], $0["size"]) }
        }
        guard let found else { throw CocoaError(.fileNoSuchFile) }
        let bytes = try archive.rawMessage(hash: found.hash, state: found.state)
        return RawMessage(key: key, internalDate: Date(timeIntervalSince1970: TimeInterval(found.date)), size: found.size, bytes: bytes)
    }
}

/// What `verify --server` checks in the archive for a Gmail account that syncs
/// through the API (D-591, D-594): counts only, never content.
public struct GmailArchiveRows: Sendable, Equatable {
    /// Gmail IDs held by more than one synced message: a download that should have been an adoption.
    public var duplicateGmailIDs = 0
    /// All Mail copies the server still has that keep an IMAP UID: not yet carried across to the API.
    public var allMailRowsWithUID = 0
    /// All Mail copies the server still has, held as API copies with no UID.
    public var allMailAPIRows = 0
    /// Messages removed from the archive (tombstones) for this account.
    public var tombstones = 0

    public init(duplicateGmailIDs: Int = 0, allMailRowsWithUID: Int = 0, allMailAPIRows: Int = 0, tombstones: Int = 0) {
        self.duplicateGmailIDs = duplicateGmailIDs
        self.allMailRowsWithUID = allMailRowsWithUID
        self.allMailAPIRows = allMailAPIRows
        self.tombstones = tombstones
    }

    public var isClean: Bool { duplicateGmailIDs == 0 && allMailRowsWithUID == 0 }

    public static func count(_ archive: Archive, account: AccountID) throws -> GmailArchiveRows {
        try archive.database.read { db in
            let id = account.rawValue
            var rows = GmailArchiveRows()
            rows.duplicateGmailIDs = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (SELECT gmail_msgid FROM messages WHERE account_id = ? AND gmail_msgid IS NOT NULL AND \(try ArchiveSchema.origin(db)) = 'synced'
                GROUP BY gmail_msgid HAVING count(*) > 1)
                """, arguments: [id]) ?? 0
            let copies = """
                FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                WHERE f.account_id = ? AND f.special_use = '\\all' AND mf.removed_from_server_at IS NULL
                """
            rows.allMailRowsWithUID = try Int.fetchOne(db, sql: "SELECT count(*) \(copies) AND mf.uid IS NOT NULL", arguments: [id]) ?? 0
            rows.allMailAPIRows = try Int.fetchOne(db, sql: "SELECT count(*) \(copies) AND mf.uid IS NULL", arguments: [id]) ?? 0
            rows.tombstones = try Int.fetchOne(db, sql: "SELECT count(*) FROM tombstones WHERE account_id = ?", arguments: [id]) ?? 0
            return rows
        }
    }
}
