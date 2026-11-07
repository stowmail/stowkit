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

    /// A Gmail message read through the Gmail API has no IMAP place (D-583,
    /// D-591). Its key names the All Mail folder with UIDVALIDITY and UID 0,
    /// which IMAP never uses (both are nonzero, RFC 3501 2.3.1.1), and the
    /// archive stores that copy with no UID; the message is known by its Gmail ID.
    public static func gmailAPI(accountID: AccountID, allMail: String) -> RawMessageKey {
        RawMessageKey(accountID: accountID, folder: allMail, uidValidity: 0, uid: 0)
    }

    /// Whether this key stands for a copy with no IMAP place (`gmailAPI`).
    public var hasNoServerUID: Bool { uidValidity == 0 && uid == 0 }

    /// Account, validity and UID only. The folder name can be personal, so it is left out.
    public var description: String {
        hasNoServerUID ? "\(accountID)/gmail-api" : "\(accountID)/v\(uidValidity)/\(uid)"
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
    /// IMAP flags of this copy when it was downloaded, as the server wrote them
    /// (for example `\Seen`, `\Flagged`). Read only: fetching them changes nothing.
    public var flags: [String]
    /// The complete message. Never log it.
    public var bytes: Data

    public init(
        key: RawMessageKey,
        labels: [String] = [],
        gmailMessageID: UInt64? = nil,
        gmailThreadID: UInt64? = nil,
        internalDate: Date,
        size: Int,
        flags: [String] = [],
        bytes: Data
    ) {
        self.key = key
        self.labels = labels
        self.gmailMessageID = gmailMessageID
        self.gmailThreadID = gmailThreadID
        self.internalDate = internalDate
        self.size = size
        self.flags = flags
        self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey {
        case key, labels, gmailMessageID, gmailThreadID, internalDate, size, flags, bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(RawMessageKey.self, forKey: .key)
        labels = try container.decode([String].self, forKey: .labels)
        gmailMessageID = try container.decodeIfPresent(UInt64.self, forKey: .gmailMessageID)
        gmailThreadID = try container.decodeIfPresent(UInt64.self, forKey: .gmailThreadID)
        internalDate = try container.decode(Date.self, forKey: .internalDate)
        size = try container.decode(Int.self, forKey: .size)
        // Phase 1 files were written before flags were kept.
        flags = try container.decodeIfPresent([String].self, forKey: .flags) ?? []
        bytes = try container.decode(Data.self, forKey: .bytes)
    }
}

/// Where sync writes downloaded messages.
///
/// Rules every implementation follows:
/// - `write` is idempotent by `RawMessageKey`: writing the same key again succeeds and
///   leaves one copy.
/// - A message is only durable once `flush()` returns. Sync tells its
///   `SyncStateStore` a message is downloaded only after `flush()`, never before,
///   so a crash can repeat a download but never lose one.
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

/// Archived Gmail messages by Gmail's own ID, for comparing them with what the
/// Gmail API holds (`stowmail verify --server`, D-593). Gmail messages are named
/// by ID, not by folder and UID, once sync reads them through the API (D-583).
public protocol GmailMessageSource: Sendable {
    /// The Gmail ID (`X-GM-MSGID`) of every archived message still at Gmail, sorted.
    func listGmailMessageIDs() async throws -> [UInt64]
    /// The archived bytes of the message with this Gmail ID.
    func readGmailMessage(_ id: UInt64) async throws -> Data
    /// The thread ID (`X-GM-THRID`) stored with the message, if any.
    func storedGmailThreadID(_ id: UInt64) async throws -> UInt64?
}

extension GmailMessageSource {
    public func storedGmailThreadID(_ id: UInt64) async throws -> UInt64? { nil }
}
