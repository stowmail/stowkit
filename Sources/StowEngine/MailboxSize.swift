import Foundation
import GRDB
import StowCore
import StowStore
import StowSync

/// An account's size at the provider, for the first-run screen before any
/// download: "28,760 emails, your mail uses 6.2 GB of 15 GB" (R6, D-055 step 5, D-404).
public struct MailboxSize: Sendable, Equatable {
    public var account: AccountID
    /// Messages sync found: still to download plus already archived and still at the provider.
    public var messages: Int
    /// Their RFC822.SIZE values added up.
    public var bytes: Int64
    /// Exchange's RFC822.SIZE values are estimates, so Microsoft totals are approximate.
    public var sizesAreEstimates: Bool
    /// The storage limit, when an IMAP server answered GETQUOTAROOT; nil otherwise,
    /// including Gmail through the API, which reports no storage use: show the mail size alone.
    public var quota: MailboxQuota?
    /// Whether the server offered QUOTA after sign-in at all.
    public var quotaAdvertised: Bool
}

extension EngineSync {
    /// Lists every folder of the account (no message is downloaded, nothing is
    /// compared) and adds up what the listing recorded, with the storage quota
    /// when the server offers one. Allowed before the recovery key is confirmed:
    /// listing reads sizes, dates and the few header fields that order downloads
    /// (D-028), and stores no message content (D-055).
    public func mailboxSize(for account: Account) async throws -> MailboxSize {
        let report = try await syncer(for: account).run(SyncOptions(listOnly: true))
        var size = try MailboxSize.totals(archive, account: account.id)
        size.quota = report.quota
        size.quotaAdvertised = report.quotaAdvertised
        return size
    }
}

extension MailboxSize {
    /// What the listing recorded for the account: queued (and unfetchable)
    /// messages (IMAP's queue and Gmail's), plus archived ones still at the
    /// provider, with their sizes.
    /// Imported mail is left out: Stow does not know the provider has it (D-567).
    public static func totals(_ archive: Archive, account: AccountID) throws -> MailboxSize {
        try archive.database.read { db in
            let queued = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, coalesce(sum(q.size), 0) AS bytes
                FROM download_queue q JOIN folders f ON f.id = q.folder_id WHERE f.account_id = ?
                """, arguments: [account.rawValue])!
            // Gmail through the API queues by message ID instead (D-591), with `sizeEstimate`.
            // No such queue before `v7` (a read-only open never migrates, D-605).
            let gmailQueued = try db.tableExists("gmail_queue") ? try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM gmail_queue WHERE account_id = ?
                """, arguments: [account.rawValue])! : Row(["n": 0, "bytes": Int64(0)])
            let archived = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM messages
                WHERE account_id = ? AND source_state = 'present' AND \(try ArchiveSchema.origin(db)) = 'synced'
                """, arguments: [account.rawValue])!
            let provider = try String.fetchOne(db, sql: "SELECT provider FROM accounts WHERE id = ?", arguments: [account.rawValue])
            return MailboxSize(account: account,
                               messages: (queued["n"] as Int) + (gmailQueued["n"] as Int) + (archived["n"] as Int),
                               bytes: (queued["bytes"] as Int64) + (gmailQueued["bytes"] as Int64) + (archived["bytes"] as Int64),
                               sizesAreEstimates: Self.sizesAreEstimates(provider), quota: nil, quotaAdvertised: false)
        }
    }
}

extension MailboxSize {
    /// Whether a provider's RFC822.SIZE values are estimates: Exchange's are
    /// (D-120). iCloud's are exact: measured on 1,500 messages, none differed (D-475).
    /// Other IMAP servers are taken at their word, as the standard says sizes
    /// are exact; the fetch limits allow for a server that is wrong (D-120).
    static func sizesAreEstimates(_ provider: String?) -> Bool {
        switch provider.flatMap(Provider.init(rawValue:)) {
        case .microsoft?: true
        case .gmail?, .icloud?, .imap?, .imported?, nil: false
        }
    }
}
