import Foundation

/// Database row ID of a stored message (`messages.id` in schema v1).
public typealias StoredMessageID = Int64

/// Fields a search can match or be restricted to.
public enum SearchField: String, Sendable, Codable, CaseIterable {
    case subject
    case from
    case to
    case cc
    case body
    case attachmentName
    case attachmentText
}

/// A search request, shared by the CLI, the MCP server (Phase 3) and the app.
///
/// `text` is the free-text part. Field filters are applied as well, so
/// `text: "invoice", from: "acme"` means "invoice anywhere, and acme in From".
/// Track B parses the CLI syntax (`from:`, `has:attachment` and so on) into this.
public struct SearchQuery: Hashable, Sendable, Codable {
    /// Free text. Supports FTS5 phrase ("...") and prefix (term*) syntax.
    public var text: String
    public var from: String?
    public var to: String?
    public var subject: String?
    /// True: only messages with attachments. False: only without. Nil: either.
    public var hasAttachment: Bool?
    /// Restrict to these accounts. Empty means all accounts the caller may see.
    public var accounts: [AccountID]
    /// Inclusive lower bound on the message date.
    public var since: Date?
    /// Exclusive upper bound on the message date.
    public var before: Date?
    /// Which messages the user marked as spam at the provider to include (D-022):
    /// by default they are hidden.
    public var spam: SpamFilter
    public var limit: Int
    public var offset: Int

    public enum SpamFilter: String, Hashable, Sendable, Codable {
        /// Leave out messages marked as spam at the provider (the default).
        case hide
        /// Spam and everything else (`in:anywhere`).
        case include
        /// Only spam (`in:spam`).
        case only
    }

    public init(
        text: String,
        from: String? = nil,
        to: String? = nil,
        subject: String? = nil,
        hasAttachment: Bool? = nil,
        accounts: [AccountID] = [],
        since: Date? = nil,
        before: Date? = nil,
        spam: SpamFilter = .hide,
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.text = text
        self.from = from
        self.to = to
        self.subject = subject
        self.hasAttachment = hasAttachment
        self.accounts = accounts
        self.since = since
        self.before = before
        self.spam = spam
        self.limit = limit
        self.offset = offset
    }
}

/// One result of a search, ranked best first.
public struct SearchHit: Hashable, Sendable, Codable, Identifiable {
    public var id: StoredMessageID { messageID }

    public var messageID: StoredMessageID
    public var accountID: AccountID
    /// Gmail thread ID, or a thread key derived from References for other providers.
    public var threadKey: String?
    public var date: Date
    public var from: EmailAddress?
    public var subject: String?
    /// A short extract around the match, with matches marked by `[` and `]`.
    public var snippet: String
    /// bm25 rank: lower is better (SQLite convention).
    public var rank: Double
    public var matchedFields: Set<SearchField>
    public var hasAttachments: Bool
    /// True while an attachment of this message still waits for OCR.
    public var ocrPending: Bool

    public init(
        messageID: StoredMessageID,
        accountID: AccountID,
        threadKey: String? = nil,
        date: Date,
        from: EmailAddress? = nil,
        subject: String? = nil,
        snippet: String,
        rank: Double,
        matchedFields: Set<SearchField> = [],
        hasAttachments: Bool = false,
        ocrPending: Bool = false
    ) {
        self.messageID = messageID
        self.accountID = accountID
        self.threadKey = threadKey
        self.date = date
        self.from = from
        self.subject = subject
        self.snippet = snippet
        self.rank = rank
        self.matchedFields = matchedFields
        self.hasAttachments = hasAttachments
        self.ocrPending = ocrPending
    }
}

/// Runs searches. Implemented by `StowSearch` (Track B); used by the CLI, MCP and the app.
public protocol MessageSearching: Sendable {
    func search(_ query: SearchQuery) async throws -> [SearchHit]
}
