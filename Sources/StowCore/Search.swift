import Foundation

/// Database row ID of a stored message (`messages.id` in schema v1).
public typealias StoredMessageID = Int64

/// Database row ID of a folder or Gmail label (`folders.id` in schema v1).
public typealias FolderID = Int64

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
    /// Only messages currently in this folder or label (D-079). Nil: anywhere.
    public var place: PlaceFilter?
    public var limit: Int
    public var offset: Int

    /// A folder or Gmail label to search within (D-079).
    public enum PlaceFilter: Hashable, Sendable, Codable {
        /// One folder or label, by ID (the app's sidebar, which lists them with `folders(accounts:)`).
        case folder(FolderID)
        /// Every folder or label with this name in the query's accounts (`in:` and MCP).
        /// Matched case-insensitively; also matches a Gmail system label written
        /// without its backslash (`inbox` for `\Inbox`) and a folder by its
        /// special use (`sent` for a folder flagged `\Sent`).
        case named(String)
    }

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
        place: PlaceFilter? = nil,
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
        self.place = place
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

/// A folder or Gmail label that search can filter by (D-079).
public struct ArchiveFolder: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// An IMAP folder (Microsoft, and Gmail's All Mail).
        case folder
        /// A Gmail label, as `X-GM-LABELS` names it (`\Inbox`, `Project X`).
        case label
    }

    public var id: FolderID
    public var accountID: AccountID
    /// Full IMAP path, or the Gmail label.
    public var name: String
    public var kind: Kind
    /// RFC 6154 special use, lowercased (`\sent`, `\trash`, `\all`), if any.
    public var specialUse: String?
    /// Hierarchy separator, for showing folders as a tree.
    public var delimiter: String?

    public init(id: FolderID, accountID: AccountID, name: String, kind: Kind, specialUse: String? = nil, delimiter: String? = nil) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.kind = kind
        self.specialUse = specialUse
        self.delimiter = delimiter
    }
}

/// One message of a conversation: enough for a collapsed row, no body (D-079).
public struct ThreadMessage: Hashable, Sendable, Codable, Identifiable {
    public var id: StoredMessageID { messageID }

    public var messageID: StoredMessageID
    public var date: Date
    public var from: EmailAddress?
    public var subject: String?
    public var sourceState: SourceState
    public var hasAttachments: Bool

    public init(messageID: StoredMessageID, date: Date, from: EmailAddress? = nil, subject: String? = nil,
                sourceState: SourceState = .present, hasAttachments: Bool = false) {
        self.messageID = messageID
        self.date = date
        self.from = from
        self.subject = subject
        self.sourceState = sourceState
        self.hasAttachments = hasAttachments
    }
}

/// The conversation around one message, oldest first (D-054, D-079).
public struct MessageThread: Hashable, Sendable, Codable {
    /// Most `messages` holds; a longer thread is cut to a window around the given message.
    public static let maximumMessages = 500

    public var accountID: AccountID
    public var threadKey: String?
    public var messages: [ThreadMessage]
    /// Index in `messages` of the message asked about.
    public var selectedIndex: Int
    /// How many messages the whole thread has (spam rule applied), even when `messages` is cut.
    public var totalCount: Int
    /// True when `messages` is a window of a longer thread.
    public var truncated: Bool { totalCount > messages.count }

    public init(accountID: AccountID, threadKey: String?, messages: [ThreadMessage], selectedIndex: Int, totalCount: Int) {
        self.accountID = accountID
        self.threadKey = threadKey
        self.messages = messages
        self.selectedIndex = selectedIndex
        self.totalCount = totalCount
    }
}

/// Runs searches. Implemented by `StowSearch` (Track B); used by the CLI, MCP and the app.
public protocol MessageSearching: Sendable {
    /// One page of matches: best first with text, newest first without.
    func search(_ query: SearchQuery) async throws -> [SearchHit]
    /// How many messages match, across every page. `limit` and `offset` are ignored.
    func count(_ query: SearchQuery) async throws -> Int
    /// The folders and labels of these accounts (all if empty) that hold archived mail.
    func folders(accounts: [AccountID]) async throws -> [ArchiveFolder]
    /// The conversation around a message, or nil if there is no such message.
    func thread(of message: StoredMessageID) async throws -> MessageThread?
}
