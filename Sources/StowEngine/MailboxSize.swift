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
    /// The storage limit, when the server answered GETQUOTAROOT (Gmail); nil otherwise:
    /// then show the mail size alone. Gmail's usage is the whole Google account's.
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
    /// messages, plus archived ones still at the provider, with their sizes.
    public static func totals(_ archive: Archive, account: AccountID) throws -> MailboxSize {
        try archive.database.read { db in
            let queued = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, coalesce(sum(q.size), 0) AS bytes
                FROM download_queue q JOIN folders f ON f.id = q.folder_id WHERE f.account_id = ?
                """, arguments: [account.rawValue])!
            let archived = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM messages WHERE account_id = ? AND source_state = 'present'
                """, arguments: [account.rawValue])!
            let provider = try String.fetchOne(db, sql: "SELECT provider FROM accounts WHERE id = ?", arguments: [account.rawValue])
            return MailboxSize(account: account, messages: (queued["n"] as Int) + (archived["n"] as Int),
                               bytes: (queued["bytes"] as Int64) + (archived["bytes"] as Int64),
                               sizesAreEstimates: provider == Provider.microsoft.rawValue, quota: nil, quotaAdvertised: false)
        }
    }
}
