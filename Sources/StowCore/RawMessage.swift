import Foundation

/// Identifies one downloaded copy of a message on the server.
///
/// IMAP guarantees that a UID never changes meaning while the folder's
/// UIDVALIDITY stays the same, so these four values together name one message
/// copy. Sinks treat a second write with the same key as a duplicate, which is
/// what makes an interrupted sync safe to repeat.
public struct RawMessageKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let accountID: AccountID
    /// The IMAP mailbox name the message was fetched from, decoded from modified UTF-7.
    /// For Gmail this is the All Mail folder; labels are carried separately.
    public let folder: String
    public let uidValidity: UInt32
    public let uid: UInt32

    public init(accountID: AccountID, folder: String, uidValidity: UInt32, uid: UInt32) {
        self.accountID = accountID
        self.folder = folder
        self.uidValidity = uidValidity
        self.uid = uid
    }

    public static func < (lhs: RawMessageKey, rhs: RawMessageKey) -> Bool {
        (lhs.accountID.rawValue, lhs.folder, lhs.uidValidity, lhs.uid)
            < (rhs.accountID.rawValue, rhs.folder, rhs.uidValidity, rhs.uid)
    }

    /// Account, validity and UID only. The folder name can be personal, so it is left out.
    public var description: String {
        "\(accountID)/v\(uidValidity)/\(uid)"
    }
}

/// One message exactly as the server sent it, plus the IMAP metadata that came with it.
///
/// This is the hand-off between sync (Track A, which produces these) and storage
/// (Track B, which parses and stores them). `bytes` is the full RFC 5322 message
/// from `BODY.PEEK[]`, untouched: line endings, encodings and all.
public struct RawMessage: Sendable, Codable, Equatable {
    public let key: RawMessageKey
    /// Gmail labels from `X-GM-LABELS`, decoded. Empty for Microsoft accounts.
    public var labels: [String]
    /// Gmail's permanent message ID (`X-GM-MSGID`). Nil for Microsoft accounts.
    public var gmailMessageID: UInt64?
    /// Gmail's thread ID (`X-GM-THRID`). Nil for Microsoft accounts.
    public var gmailThreadID: UInt64?
    /// The server's INTERNALDATE: when the message arrived in the mailbox.
    /// More trustworthy than the Date header, which senders set themselves.
    public var internalDate: Date
    /// RFC822.SIZE as reported by the server, in bytes.
    public var size: Int
    /// The complete message. Never log it.
    public var bytes: Data

    public init(
        key: RawMessageKey,
        labels: [String] = [],
        gmailMessageID: UInt64? = nil,
        gmailThreadID: UInt64? = nil,
        internalDate: Date,
        size: Int,
        bytes: Data
    ) {
        self.key = key
        self.labels = labels
        self.gmailMessageID = gmailMessageID
        self.gmailThreadID = gmailThreadID
        self.internalDate = internalDate
        self.size = size
        self.bytes = bytes
    }
}

/// Where sync writes downloaded messages.
///
/// Rules every implementation follows:
/// - `write` is idempotent by `RawMessageKey`: writing the same key again succeeds and
///   leaves one copy.
/// - A message is only durable once `flush()` returns. Sync saves its
///   `SyncCheckpoint` after `flush()`, never before, so a crash can repeat a batch
///   but never skip one.
public protocol RawMessageSink: Sendable {
    func write(_ message: RawMessage) async throws
    func flush() async throws
}

/// Where storage reads downloaded messages from.
public protocol RawMessageSource: Sendable {
    /// Every complete message available, sorted by key. Partially written
    /// messages are never listed.
    func listKeys() async throws -> [RawMessageKey]
    func read(_ key: RawMessageKey) async throws -> RawMessage
}

/// Progress marker for one folder of one account.
///
/// Sync resumes from `highestUID + 1`. If the server reports a different
/// UIDVALIDITY, every UID in the folder has changed meaning, so the folder is
/// synced again from the start (the sink tolerates the duplicates).
public struct SyncCheckpoint: Hashable, Sendable, Codable {
    public let accountID: AccountID
    public let folder: String
    public var uidValidity: UInt32
    /// The highest UID written to the sink and flushed. Zero means nothing yet.
    public var highestUID: UInt32
    public var updatedAt: Date

    public init(accountID: AccountID, folder: String, uidValidity: UInt32, highestUID: UInt32, updatedAt: Date = Date()) {
        self.accountID = accountID
        self.folder = folder
        self.uidValidity = uidValidity
        self.highestUID = highestUID
        self.updatedAt = updatedAt
    }
}

/// Where sync keeps its checkpoints. File-based until Phase 2, then the `sync_state` table.
public protocol SyncCheckpointStore: Sendable {
    func checkpoint(accountID: AccountID, folder: String) async throws -> SyncCheckpoint?
    func save(_ checkpoint: SyncCheckpoint) async throws
}
