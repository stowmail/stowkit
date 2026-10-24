import Foundation
import GRDB
import StowCore

/// Everything `stowmail coverage` reports for one account (D-021, D-034).
/// Counts, sizes and dates only.
public struct CoverageReport: Sendable, Equatable {
    public var account: AccountID
    /// Every message the server had before this date is archived and verified.
    /// Nil until every synced folder has been listed.
    public var coverageDate: Date?
    /// Why the coverage date is held back, in plain words, when it is.
    public var heldBackBy: String?
    /// Listed but not yet downloaded, and recorded as never downloadable (D-115).
    public var queued = 0
    public var unfetchable = 0
    public var oldestNotArchived: Date?
    public var retentionMonths: Int?
    /// Mail older than this is what the user's retention would delete from the server.
    public var retentionCutoff: Date?
    /// Archived messages older than the coverage date (and the retention cutoff,
    /// when one is set) that are still on the server: safe to delete there.
    public var safeToDelete = 0
    public var safeToDeleteBytes = 0
    /// True when the coverage date reaches the retention cutoff, so deletion
    /// instructions can be offered (D-021).
    public var coversRetention = false
    /// Not yet archived, and within the warning window of the retention cutoff:
    /// retention would delete these from the server soon (D-021 step 4).
    public var atRisk = 0
    /// The date to put in deletion instructions: one day before the cutoff, to
    /// stay clear of time zone differences. Nil unless `coversRetention`.
    public var deleteBefore: Date?
}

/// The coverage date and what follows from it (D-021, D-034).
public enum Coverage {
    /// Days before the retention cutoff in which mail not yet archived is warned about.
    public static let warningDays = 30

    /// Works it out, and stores the coverage date on the account for status.
    public static func compute(_ archive: Archive, account: AccountID, retentionMonths override: Int? = nil,
                               now: Date = Date()) throws -> CoverageReport {
        try archive.database.write { db in
            var report = CoverageReport(account: account)
            report.retentionMonths = try override
                ?? Int.fetchOne(db, sql: "SELECT retention_months FROM accounts WHERE id = ?", arguments: [account.rawValue])

            try measure(db, into: &report)
            try db.execute(sql: "UPDATE accounts SET coverage_date = ?, coverage_computed_at = ? WHERE id = ?",
                           arguments: [report.coverageDate.map { Int($0.timeIntervalSince1970) }, Int(now.timeIntervalSince1970),
                                       account.rawValue])

            if let months = report.retentionMonths {
                report.retentionCutoff = Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: now)
            }
            guard let coverage = report.coverageDate else { return report }
            let limit = min(coverage, report.retentionCutoff ?? coverage)
            let safe = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM messages
                WHERE account_id = ? AND source_state = 'present' AND internal_date < ?
                """, arguments: [account.rawValue, Int(limit.timeIntervalSince1970)])!
            report.safeToDelete = safe["n"]
            report.safeToDeleteBytes = safe["bytes"]
            if let cutoff = report.retentionCutoff {
                report.coversRetention = coverage >= cutoff
                if report.coversRetention {
                    report.deleteBefore = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: cutoff)
                }
                let warnUntil = cutoff.addingTimeInterval(TimeInterval(warningDays * 86_400))
                report.atRisk = try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM download_queue q JOIN folders f ON f.id = q.folder_id
                    WHERE f.account_id = ? AND q.internal_date < ?
                    """, arguments: [account.rawValue, Int(warnUntil.timeIntervalSince1970)]) ?? 0
            }
            return report
        }
    }

    /// The coverage date and what holds it back, from the folders' listings and
    /// the queue, without storing anything: `status` uses it inside its own read,
    /// so it is never stale.
    public static func measure(_ db: Database, into report: inout CoverageReport) throws {
        let account = report.account
        // Every synced folder must have been listed for any date to be claimed.
        let folders = try Row.fetchAll(db, sql: """
            SELECT s.last_sync_at FROM folders f LEFT JOIN sync_state s ON s.folder_id = f.id
            WHERE f.account_id = ? AND f.kind = 'folder' AND f.skipped_reason IS NULL AND f.is_selectable = 1
            """, arguments: [account.rawValue])
        let listedAt = folders.map { $0["last_sync_at"] as Int64? }
        let queue = try Row.fetchOne(db, sql: """
            SELECT coalesce(sum(q.state = 'queued'), 0) AS queued, coalesce(sum(q.state = 'unfetchable'), 0) AS unfetchable,
                   min(q.internal_date) AS oldest, coalesce(sum(q.internal_date IS NULL), 0) AS undated
            FROM download_queue q JOIN folders f ON f.id = q.folder_id WHERE f.account_id = ?
            """, arguments: [account.rawValue])!
        report.queued = queue["queued"]
        report.unfetchable = queue["unfetchable"]
        report.oldestNotArchived = (queue["oldest"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        if folders.isEmpty || listedAt.contains(where: { $0 == nil }) {
            report.heldBackBy = "the first sync has not listed every folder yet"
        } else if queue["undated"] as Int > 0 {
            report.heldBackBy = "some listed messages have no arrival date yet"
        } else {
            let lastListed = Date(timeIntervalSince1970: TimeInterval(listedAt.compactMap { $0 }.min()!))
            if let oldest = report.oldestNotArchived, oldest < lastListed {
                report.coverageDate = oldest
                report.heldBackBy = report.unfetchable > 0 && report.queued == 0
                    ? "\(report.unfetchable) message(s) the server would not return"
                    : "\(report.queued + report.unfetchable) message(s) not downloaded yet"
            } else {
                report.coverageDate = lastListed
            }
        }
    }

    /// Stores how many months the user keeps mail on the server, or nil for "not set".
    public static func setRetention(_ archive: Archive, account: AccountID, months: Int?) throws {
        try archive.database.write { db in
            try db.execute(sql: "UPDATE accounts SET retention_months = ? WHERE id = ?", arguments: [months, account.rawValue])
        }
    }
}
