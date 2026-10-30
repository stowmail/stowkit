import Foundation
import GRDB
import Logging
import StowCore

/// What a backfill run did. Counts only, never content.
public struct SenderDMARCBackfillSummary: Sendable, Equatable, CustomStringConvertible {
    /// Given `pass`, `fail` or `none` from their header block.
    public var read = 0
    /// Their raw file or header block could not be read: given `none`.
    public var unreadable = 0
    /// Stopped before the end; the next run goes on from the first message still without a result.
    public var stopped = false

    public init(read: Int = 0, unreadable: Int = 0, stopped: Bool = false) {
        self.read = read
        self.unreadable = unreadable
        self.stopped = stopped
    }

    public var description: String { "\(read) read, \(unreadable) unreadable\(stopped ? ", stopped" : "")" }
}

/// Reads the provider's DMARC result for messages stored without one (D-521, D-522):
/// those archived before schema v3, and any an older build inserts later.
///
/// Batches of `batchSize` in ID order, each continuing from the last ID of the
/// one before, so a message that cannot be read never holds up the rest. Each
/// message's raw file is opened on its own and only its header block is
/// parsed; the file is let go before the next. A file or header block that
/// cannot be read gives `none`, so the message leaves `messages_dmarc_pending`
/// and is not tried at every start. Results are written once per batch, and
/// whatever was read before a stop, in one transaction, and only where the
/// column is still NULL. Stopping at any point (or a crash) loses at most the
/// unwritten part of one batch, which the next run reads again.
public struct SenderDMARCBackfill: Sendable {
    public static let batchSize = 500
    /// D-522's batch: reads only `messages_dmarc_pending`.
    static let batchSQL = "SELECT id FROM messages WHERE sender_dmarc IS NULL AND id > :after ORDER BY id LIMIT :limit"
    /// D-522's "how many left": reads only `messages_dmarc_pending`.
    static let pendingSQL = "SELECT count(*) FROM messages WHERE sender_dmarc IS NULL"

    public let archive: Archive
    let batchSize: Int
    private let logger = Logger(label: "ee.getstow.store.dmarc-backfill")

    public init(archive: Archive) {
        self.init(archive: archive, batchSize: Self.batchSize)
    }

    init(archive: Archive, batchSize: Int) {
        self.archive = archive
        self.batchSize = batchSize
    }

    /// Messages still without a result.
    public func pending() throws -> Int {
        try archive.database.read { db in try Int.fetchOne(db, sql: Self.pendingSQL) ?? 0 }
    }

    /// Reads every message still without a result. `shouldStop` is asked before
    /// each message; when it says yes, what was read is written and the run ends.
    public func run(shouldStop: () -> Bool = { false }) throws -> SenderDMARCBackfillSummary {
        let providers = try archive.database.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT id, provider FROM accounts").map {
                ($0["id"] as String, Provider(rawValue: $0["provider"]))
            }, uniquingKeysWith: { first, _ in first })
        }
        var summary = SenderDMARCBackfillSummary()
        var after: Int64 = 0
        while true {
            let start = after
            let ids = try archive.database.read { db in
                try Int64.fetchAll(db, sql: Self.batchSQL, arguments: ["after": start, "limit": batchSize])
            }
            guard let last = ids.last else { break }
            var results: [(id: Int64, result: SenderDMARC)] = []
            for id in ids {
                if shouldStop() {
                    summary.stopped = true
                    break
                }
                do {
                    guard let result = try autoreleasepool(invoking: { try read(id, providers: providers) }) else { continue }
                    results.append((id, result))
                    summary.read += 1
                } catch {
                    results.append((id, .none))
                    summary.unreadable += 1
                }
            }
            try archive.database.write { db in
                for (id, result) in results {
                    try db.execute(sql: "UPDATE messages SET sender_dmarc = ? WHERE id = ? AND sender_dmarc IS NULL",
                                   arguments: [result.rawValue, id])
                }
            }
            if summary.stopped { break }
            after = last
        }
        if summary.unreadable > 0 {
            logger.warning("Some emails' stored files could not be read for the provider's check; they show no billing label",
                           metadata: ["unreadable": "\(summary.unreadable)"])
        }
        return summary
    }

    /// The result from the message's header block alone, or nil if the message is gone.
    func read(_ id: Int64, providers: [String: Provider?]) throws -> SenderDMARC? {
        guard let row = try archive.database.read({ db in
            try Row.fetchOne(db, sql: "SELECT account_id, raw_hash, raw_state FROM messages WHERE id = ?", arguments: [id])
        }) else { return nil }
        let stored = try archive.rawFiles.read(row["raw_hash"])
        let block = row["raw_state"] as String == "skeleton"
            ? try RawCompaction.headerBlock(ofSkeleton: stored) : RawCompaction.headerBlock(of: stored)
        return Importer.senderDMARC(HeaderParser().parseHeaders(block), provider: providers[row["account_id"] as String] ?? nil)
    }
}
