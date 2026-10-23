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
    public var sourceStates: [SourceState: Int] = [:]
    public var removed = 0

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
            try Row.fetchAll(db, sql: """
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
                status.coverageDate = date("coverage_date")
                let messages = try Row.fetchOne(db, sql: """
                    SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM messages WHERE account_id = ?
                    """, arguments: [id])!
                status.archivedMessages = messages["n"]
                status.archivedBytes = messages["bytes"]
                let queue = try Row.fetchOne(db, sql: """
                    SELECT coalesce(sum(q.state = 'queued'), 0) AS queued,
                           coalesce(sum(CASE WHEN q.state = 'queued' THEN q.size ELSE 0 END), 0) AS bytes,
                           coalesce(sum(q.state = 'unfetchable'), 0) AS unfetchable
                    FROM download_queue q JOIN folders f ON f.id = q.folder_id WHERE f.account_id = ?
                    """, arguments: [id])!
                status.queue = QueueTotals(queued: queue["queued"], queuedBytes: queue["bytes"], unfetchable: queue["unfetchable"])
                let folders = try Row.fetchAll(db, sql: """
                    SELECT s.first_sync_completed_at, s.status, s.last_error FROM folders f JOIN sync_state s ON s.folder_id = f.id
                    WHERE f.account_id = ? AND f.kind = 'folder' AND f.skipped_reason IS NULL
                    """, arguments: [id])
                status.foldersSynced = folders.count
                status.firstSyncComplete = !folders.isEmpty && folders.allSatisfy { ($0["first_sync_completed_at"] as Int64?) != nil }
                status.folderErrors = folders.compactMap { $0["status"] as String == "error" ? $0["last_error"] as String? : nil }
                status.bytesLast24Hours = try Int64.fetchOne(db, sql: """
                    SELECT coalesce(sum(bytes), 0) FROM byte_budget WHERE account_id = ? AND at > ?
                    """, arguments: [id, Int(now.timeIntervalSince1970) - 86_400]) ?? 0
                for row in try Row.fetchAll(db, sql: """
                    SELECT source_state, count(*) AS n FROM messages WHERE account_id = ? AND source_state != 'present' GROUP BY source_state
                    """, arguments: [id]) {
                    if let state = SourceState(rawValue: row["source_state"]) { status.sourceStates[state] = row["n"] }
                }
                status.removed = try Int.fetchOne(db, sql: "SELECT count(*) FROM tombstones WHERE account_id = ?", arguments: [id]) ?? 0
                return status
            }
        }
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
