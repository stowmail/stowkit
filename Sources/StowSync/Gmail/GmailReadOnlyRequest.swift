import Foundation

/// The complete list of Gmail API calls Stow can make (D-583).
///
/// Each case is a GET on `https://gmail.googleapis.com/gmail/v1/users/me/...`,
/// and `GmailClient` sends only values of this type, so a call that changes the
/// mailbox (`modify`, `trash`, `send`, `insert`, `import`, `watch`, drafts,
/// settings and the rest) cannot be expressed: there is no case for it. This is
/// the HTTP counterpart of `ReadOnlyCommand` (D-109), and the second guarantee
/// beside the `gmail.readonly` scope Google enforces.
enum GmailReadOnlyRequest: Sendable, Equatable {
    /// `users.getProfile`: the address, message count and current history ID.
    case profile
    /// `users.labels.list`: every label's ID, name and type.
    case labels
    /// `users.messages.list`: message and thread IDs, a page at a time.
    case messages(GmailMessageListQuery)
    /// `users.messages.get` in one of the formats that only read.
    case message(GmailMessageID, format: GmailMessageFormat)
    /// `users.history.list`: what changed since a history ID.
    case history(GmailHistoryQuery)

    /// The only host and path prefix any request can reach.
    static let host = "gmail.googleapis.com"
    static let pathPrefix = "/gmail/v1/users/me/"

    /// The call's name, for logs and errors. Never includes an ID or a query,
    /// which may hold a search term.
    var name: String {
        switch self {
        case .profile: "users.getProfile"
        case .labels: "users.labels.list"
        case .messages: "users.messages.list"
        case .message: "users.messages.get"
        case .history: "users.history.list"
        }
    }

    /// The request, as the only value a transport accepts.
    var get: GmailGet {
        var query: [(String, String)] = []
        let path: String
        switch self {
        case .profile:
            path = "profile"
        case .labels:
            path = "labels"
        case .messages(let list):
            path = "messages"
            if let q = list.q { query.append(("q", q)) }
            query += list.labelIDs.map { ("labelIds", $0.rawValue) }
            query.append(("includeSpamTrash", list.includeSpamTrash ? "true" : "false"))
            if let token = list.pageToken { query.append(("pageToken", token)) }
            query.append(("maxResults", String(list.maxResults)))
        case .message(let id, let format):
            path = "messages/\(id.rawValue)"
            query.append(("format", format.name))
            if case .metadata(let headers) = format {
                query += headers.map { ("metadataHeaders", $0) }
            }
        case .history(let history):
            path = "history"
            query.append(("startHistoryId", String(history.startHistoryID)))
            query += history.historyTypes.map { ("historyTypes", $0.rawValue) }
            if let label = history.labelID { query.append(("labelId", label.rawValue)) }
            if let token = history.pageToken { query.append(("pageToken", token)) }
            query.append(("maxResults", String(history.maxResults)))
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = Self.pathPrefix + path
        if !query.isEmpty { components.percentEncodedQuery = GmailQueryEncoding.encode(query) }
        return GmailGet(url: components.url!, name: name)
    }
}

/// A GET request built from a `GmailReadOnlyRequest`. Its initialiser is private
/// to this file, so nothing else in Stow can make one, and a transport cannot be
/// handed anything else. It has no method field: GET is the only one.
struct GmailGet: Sendable, Equatable, CustomStringConvertible {
    /// The one HTTP method Stow uses with Gmail.
    static let method = "GET"

    let url: URL
    let name: String

    fileprivate init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    /// The call's name only: the URL can hold a search term or a page token.
    var description: String { "GmailGet(\(name))" }
}

/// `users.messages.list` parameters.
struct GmailMessageListQuery: Sendable, Equatable {
    /// Gmail search syntax, for example `in:spam`. Usually nil.
    var q: String?
    /// Messages carrying every one of these labels.
    var labelIDs: [GmailLabelID]
    /// False lists All Mail without Spam and Bin (D-104).
    var includeSpamTrash: Bool
    var pageToken: String?
    /// 1 to 500; Google's default is 100 and its maximum 500.
    var maxResults: Int

    init(q: String? = nil, labelIDs: [GmailLabelID] = [], includeSpamTrash: Bool = false, pageToken: String? = nil, maxResults: Int = 500) {
        self.q = q
        self.labelIDs = labelIDs
        self.includeSpamTrash = includeSpamTrash
        self.pageToken = pageToken
        self.maxResults = min(max(maxResults, 1), 500)
    }
}

/// `users.history.list` parameters.
struct GmailHistoryQuery: Sendable, Equatable {
    var startHistoryID: UInt64
    var historyTypes: [GmailHistoryType]
    var labelID: GmailLabelID?
    var pageToken: String?
    var maxResults: Int

    init(startHistoryID: UInt64, historyTypes: [GmailHistoryType] = GmailHistoryType.allCases, labelID: GmailLabelID? = nil,
         pageToken: String? = nil, maxResults: Int = 500) {
        self.startHistoryID = startHistoryID
        self.historyTypes = historyTypes
        self.labelID = labelID
        self.pageToken = pageToken
        self.maxResults = min(max(maxResults, 1), 500)
    }
}

/// The kinds of change `users.history.list` can report.
enum GmailHistoryType: String, Sendable, CaseIterable {
    case messageAdded, messageDeleted, labelAdded, labelRemoved
}

/// The `users.messages.get` formats Stow uses. `full` is left out: `raw` gives
/// the original bytes, which is what the archive keeps.
enum GmailMessageFormat: Sendable, Equatable {
    /// The RFC 822 message, base64url-encoded.
    case raw
    /// IDs, labels, size and date only.
    case minimal
    /// As `minimal` plus the named header fields.
    case metadata(headers: [String])

    var name: String {
        switch self {
        case .raw: "raw"
        case .minimal: "minimal"
        case .metadata: "metadata"
        }
    }
}

/// A Gmail message or thread ID: the hex form of `X-GM-MSGID` or `X-GM-THRID`
/// (Google's IMAP extensions page). Only lowercase hex digits are accepted, so
/// an ID, even one read from a reply, can never add a path segment to a request.
struct GmailMessageID: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    let rawValue: String

    init?(_ text: String) {
        guard (1...16).contains(text.utf8.count), text.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        rawValue = text
    }

    /// The same ID as IMAP's 64-bit `X-GM-MSGID`.
    init(number: UInt64) {
        rawValue = String(number, radix: 16)
    }

    /// The ID as the 64-bit number IMAP and Takeout use.
    var number: UInt64 { UInt64(rawValue, radix: 16)! }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = GmailMessageID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a Gmail ID"))
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.number < rhs.number }

    var description: String { rawValue }
}

/// A Gmail label ID: `INBOX`, `CATEGORY_SOCIAL` or `Label_12`. Letters, digits,
/// `_` and `-` only, so it cannot change a request's path or query.
struct GmailLabelID: Sendable, Hashable, Codable, CustomStringConvertible {
    let rawValue: String

    init?(_ text: String) {
        guard (1...128).contains(text.utf8.count), text.utf8.allSatisfy({
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x5F || $0 == 0x2D
        }) else { return nil }
        rawValue = text
    }

    static let spam = GmailLabelID("SPAM")!
    static let trash = GmailLabelID("TRASH")!

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = GmailLabelID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a Gmail label ID"))
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}

/// Query strings for the Gmail API. Everything outside RFC 3986's unreserved
/// characters is percent-encoded, including `+`, `&`, `=` and `/`, which
/// `URLComponents.queryItems` would leave alone.
enum GmailQueryEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return set
    }()

    static func encode(_ items: [(String, String)]) -> String {
        items.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}
