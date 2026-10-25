import Foundation

// The contract between sync and wherever its progress is kept (D-027).
//
// Phase 1 kept one checkpoint per folder: "everything up to UID n is done".
// Phase 2 keeps a download queue instead. Listing a folder puts every new
// message in the queue (with a priority, so personal mail can come before bulk
// mail, D-028), and downloading takes from the queue. So a message that cannot
// be downloaded never holds up the ones after it, the queue survives restarts,
// and a first sync that takes days carries on where it stopped.
//
// The archive implements this in its database (`ArchiveSyncStore`); tests and
// the development store use an in-memory one (`MemorySyncState`).

/// A mailbox as the server's LIST described it, and what sync does with it.
public struct SyncFolder: Sendable, Hashable {
    public var name: String
    public var delimiter: String?
    /// RFC 6154 special use, lowercased, for example `\all`, `\trash`, `\junk`.
    public var specialUse: String?
    public var isSelectable: Bool
    /// Why sync leaves this folder out, or nil if it is synced.
    public var skippedReason: String?

    public init(name: String, delimiter: String? = nil, specialUse: String? = nil, isSelectable: Bool = true, skippedReason: String? = nil) {
        self.name = name
        self.delimiter = delimiter
        self.specialUse = specialUse
        self.isSelectable = isSelectable
        self.skippedReason = skippedReason
    }
}

/// How far sync has got with one folder.
public struct FolderSyncState: Sendable, Equatable {
    public var uidValidity: UInt32
    /// Every UID up to this one has been listed: it is archived, queued,
    /// recorded as unfetchable, or was never there. Listing resumes above it.
    public var listedThroughUID: UInt32
    /// CONDSTORE's HIGHESTMODSEQ when flags were last brought up to date (D-038).
    public var highestModSeq: UInt64?
    /// When the folder was last compared in full with the server (flags and deletions).
    public var lastFullCheckAt: Date?
    /// When the queue for this folder first emptied: its first sync is done.
    public var firstSyncCompletedAt: Date?

    public init(uidValidity: UInt32, listedThroughUID: UInt32 = 0, highestModSeq: UInt64? = nil,
                lastFullCheckAt: Date? = nil, firstSyncCompletedAt: Date? = nil) {
        self.uidValidity = uidValidity
        self.listedThroughUID = listedThroughUID
        self.highestModSeq = highestModSeq
        self.lastFullCheckAt = lastFullCheckAt
        self.firstSyncCompletedAt = firstSyncCompletedAt
    }
}

/// One listed message waiting to be downloaded.
public struct QueuedMessage: Sendable, Equatable {
    public var folder: String
    public var uidValidity: UInt32
    public var uid: UInt32
    /// RFC822.SIZE: an estimate on Exchange (D-120), used for batching and the budget.
    public var size: Int
    public var internalDate: Date?
    /// Lower downloads first: 0 for mail that looks personal, higher for bulk (D-028),
    /// `newArrival` for personal mail that arrived after its folder was first walked (D-043).
    public var priority: Int
    public var gmailMessageID: UInt64?

    /// Ahead of the backlog, so new mail is searchable within a cycle even during a first sync.
    public static let newArrival = -1

    public init(folder: String, uidValidity: UInt32, uid: UInt32, size: Int, internalDate: Date? = nil,
                priority: Int = 0, gmailMessageID: UInt64? = nil) {
        self.folder = folder
        self.uidValidity = uidValidity
        self.uid = uid
        self.size = size
        self.internalDate = internalDate
        self.priority = priority
        self.gmailMessageID = gmailMessageID
    }
}

/// A queued message the server listed but did not return.
public struct FailedDownload: Sendable, Equatable {
    public var uid: UInt32
    public var flags: [String]

    public init(uid: UInt32, flags: [String] = []) {
        self.uid = uid
        self.flags = flags
    }
}

/// Totals for one account's queue.
public struct QueueTotals: Sendable, Equatable {
    public var queued = 0
    public var queuedBytes: Int64 = 0
    /// Listed on `threshold` separate runs but never returned, and passed (D-115).
    public var unfetchable = 0

    public init(queued: Int = 0, queuedBytes: Int64 = 0, unfetchable: Int = 0) {
        self.queued = queued
        self.queuedBytes = queuedBytes
        self.unfetchable = unfetchable
    }
}

/// The server's current flags, and for Gmail labels, of one stored copy.
public struct CopyState: Sendable, Equatable {
    public var uid: UInt32
    public var flags: [String]
    /// Gmail labels; nil for other providers.
    public var labels: [String]?

    public init(uid: UInt32, flags: [String], labels: [String]? = nil) {
        self.uid = uid
        self.flags = flags
        self.labels = labels
    }
}

/// What happened to an archived message at the provider (D-022). Only ever a
/// record: Stow never deletes from the archive because of it.
public enum SourceState: String, Sendable, Codable, CaseIterable {
    case present
    case spam
    case trashed
    case gone
}

/// An archived message no longer in any folder sync can see, to be classified
/// as spam, trashed or gone by looking in the provider's Spam and Trash (D-039).
public struct VanishedMessage: Sendable, Equatable {
    public var messageID: Int64
    public var gmailMessageID: UInt64?
    /// The Message-ID header, without brackets.
    public var rfc822MessageID: String?

    public init(messageID: Int64, gmailMessageID: UInt64? = nil, rfc822MessageID: String? = nil) {
        self.messageID = messageID
        self.gmailMessageID = gmailMessageID
        self.rfc822MessageID = rfc822MessageID
    }
}

/// Where sync keeps its progress. Every call is one atomic step.
public protocol SyncStateStore: Sendable {
    /// Records the account's folders as LIST showed them, synced or not.
    func recordFolders(_ account: AccountID, _ folders: [SyncFolder]) async throws

    func folderState(_ account: AccountID, folder: String) async throws -> FolderSyncState?

    /// Starts work on a folder after EXAMINE. If `uidValidity` differs from the
    /// stored one, every UID has changed meaning: queued downloads for the old
    /// value are dropped and listing starts from the beginning. Returns the old
    /// value when that happened.
    func beginFolder(_ account: AccountID, folder: String, uidValidity: UInt32, exists: Int) async throws -> UInt32?

    /// Adds newly listed messages to the queue and moves `listedThroughUID` to
    /// `listedThrough`, in one step. Leaves out messages already archived at
    /// that place, and ones the user removed from the archive (D-033). Returns
    /// how many were queued.
    @discardableResult
    func enqueue(_ account: AccountID, folder: String, uidValidity: UInt32, messages: [QueuedMessage], listedThrough: UInt32) async throws -> Int

    /// The next messages to download for the account: the best priority first,
    /// all from one folder, oldest UID first, at most `maxMessages` and, where
    /// possible, `maxBytes`. Leaves out messages that failed earlier in run `runID`.
    func nextDownloads(_ account: AccountID, runID: String, maxMessages: Int, maxBytes: Int) async throws -> [QueuedMessage]

    /// After the sink has written and flushed these messages: takes them off the queue.
    func downloaded(_ account: AccountID, folder: String, uidValidity: UInt32, uids: [UInt32]) async throws

    /// Queued messages the server deleted before they could be downloaded.
    func vanishedBeforeDownload(_ account: AccountID, folder: String, uidValidity: UInt32, uids: [UInt32]) async throws

    /// Counts one failed attempt, at most once per run, for queued messages the
    /// server still lists but did not return. Returns those that have now failed
    /// on `threshold` separate runs: they are recorded and stop being retried (D-115).
    func recordFailedAttempt(_ account: AccountID, folder: String, uidValidity: UInt32, runID: String,
                             failed: [FailedDownload], threshold: Int) async throws -> Set<UInt32>

    func queueTotals(_ account: AccountID) async throws -> QueueTotals

    /// After listing and downloading a folder in a run: stores the time, and
    /// when nothing is left queued for it marks its first sync complete (and,
    /// after a UIDVALIDITY change, retires copies the new walk did not find).
    func folderWalked(_ account: AccountID, folder: String, uidValidity: UInt32, at: Date) async throws

    // MARK: Changes at the source (D-022, D-038, D-039)

    /// Folders synced before (they have sync state), so a folder deleted on the server can be noticed.
    func syncedFolders(_ account: AccountID) async throws -> [String]

    /// UIDs of the archived copies in this folder that the server still had last time.
    func storedUIDs(_ account: AccountID, folder: String, uidValidity: UInt32) async throws -> [UInt32]

    /// UIDs still in the queue for this folder, including ones recorded as unfetchable.
    func queuedUIDs(_ account: AccountID, folder: String, uidValidity: UInt32) async throws -> [UInt32]

    /// Brings flags (and Gmail labels) of archived copies up to date.
    func applyCopyStates(_ account: AccountID, folder: String, uidValidity: UInt32, _ states: [CopyState], at: Date) async throws

    /// Marks archived copies as no longer on the server. Messages still present
    /// in another synced folder stay present; ones left only in a Trash folder
    /// become trashed. Returns the messages with no copy left anywhere sync looks,
    /// to be classified by the caller.
    func markRemovedFromServer(_ account: AccountID, folder: String, uidValidity: UInt32, uids: [UInt32], at: Date) async throws -> [VanishedMessage]

    func setSourceStates(_ account: AccountID, _ states: [Int64: SourceState], at: Date) async throws

    /// Messages with no copy left on the server whose source state was never
    /// settled, because an earlier run stopped between `markRemovedFromServer`
    /// and `setSourceStates` (for example a dropped connection while looking in
    /// Spam and Bin). A full check classifies them again (D-408).
    func unclassifiedVanished(_ account: AccountID) async throws -> [VanishedMessage]

    /// After a full comparison with the server: stores the time and CONDSTORE's HIGHESTMODSEQ.
    func folderChecked(_ account: AccountID, folder: String, uidValidity: UInt32, highestModSeq: UInt64?, fullCheck: Bool, at: Date) async throws

    // MARK: Byte budget (D-106)

    func bytesDownloaded(_ account: AccountID, since: Date) async throws -> Int64
    func recordDownload(_ account: AccountID, bytes: Int64, at: Date) async throws

    // MARK: Status

    /// Something worth keeping a record of, such as a UIDVALIDITY change. No content, no addresses.
    func recordEvent(_ account: AccountID, folder: String?, kind: String, old: String?, new: String?, at: Date) async throws

    /// The folder's last error in plain words (already scrubbed), or nil when it synced cleanly.
    func setFolderError(_ account: AccountID, folder: String, error: String?) async throws
}

/// Turns the listed header fields of a message into a download priority
/// (D-028): 0 first. The fields come from `BODY.PEEK[HEADER.FIELDS (...)]`.
public typealias DownloadPrioritiser = @Sendable (_ headerFields: Data) -> Int

/// Header fields sync lists for `DownloadPrioritiser`: everything the rules
/// engine reads, and nothing else.
public enum PriorityHeaderFields {
    public static let names = [
        "From", "Sender", "Reply-To", "To", "Cc", "Bcc", "Delivered-To", "X-Original-To", "Envelope-To",
        "X-Envelope-To", "X-Delivered-To", "Return-Path", "List-Unsubscribe", "List-Unsubscribe-Post", "List-Id",
        "Precedence", "Auto-Submitted", "Message-ID",
    ]
}
