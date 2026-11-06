import Foundation

// The parts of Gmail API replies Stow reads (Gmail API reference, read
// 4 November 2026). None of these describe themselves with an address, a
// label name or message bytes.

/// `users.getProfile`.
struct GmailProfile: Decodable, Sendable, CustomStringConvertible {
    var emailAddress: String
    var messagesTotal: Int?
    var threadsTotal: Int?
    var historyID: UInt64

    enum CodingKeys: String, CodingKey {
        case emailAddress, messagesTotal, threadsTotal
        case historyID = "historyId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        messagesTotal = try container.decodeIfPresent(Int.self, forKey: .messagesTotal)
        threadsTotal = try container.decodeIfPresent(Int.self, forKey: .threadsTotal)
        historyID = try GmailNumber.decode(container, .historyID)
    }

    var description: String { "GmailProfile(messages: \(messagesTotal.map(String.init) ?? "?"), historyId: \(historyID))" }
}

/// One entry of `users.labels.list`.
struct GmailLabel: Decodable, Sendable, Equatable, CustomStringConvertible {
    enum Kind: String, Decodable, Sendable { case system, user }

    var id: GmailLabelID
    var name: String
    var type: Kind?

    var description: String { "GmailLabel(\(type?.rawValue ?? "?") \(type == .system ? id.rawValue : "[name hidden]"))" }
}

struct GmailLabelList: Decodable, Sendable {
    var labels: [GmailLabel]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labels = try container.decodeIfPresent([GmailLabel].self, forKey: .labels) ?? []
    }

    enum CodingKeys: String, CodingKey { case labels }
}

/// A message as `users.messages.list` and `users.history.list` name it.
/// History also sends its labels; a listing does not.
struct GmailMessageRef: Decodable, Sendable, Equatable {
    var id: GmailMessageID
    var threadID: GmailMessageID
    var labelIDs: [GmailLabelID] = []

    enum CodingKeys: String, CodingKey {
        case id, labelIds
        case threadID = "threadId"
    }

    init(id: GmailMessageID, threadID: GmailMessageID, labelIDs: [GmailLabelID] = []) {
        self.id = id
        self.threadID = threadID
        self.labelIDs = labelIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(GmailMessageID.self, forKey: .id)
        threadID = try container.decode(GmailMessageID.self, forKey: .threadID)
        labelIDs = try container.decodeIfPresent([GmailLabelID].self, forKey: .labelIds) ?? []
    }
}

/// One page of `users.messages.list`. Google leaves `messages` out of an empty page.
struct GmailMessageList: Decodable, Sendable {
    var messages: [GmailMessageRef]
    var nextPageToken: String?
    var resultSizeEstimate: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([GmailMessageRef].self, forKey: .messages) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        resultSizeEstimate = try container.decodeIfPresent(Int.self, forKey: .resultSizeEstimate)
    }

    enum CodingKeys: String, CodingKey { case messages, nextPageToken, resultSizeEstimate }
}

/// `users.messages.get` in `raw`, `minimal` or `metadata` format.
struct GmailMessage: Decodable, Sendable, CustomStringConvertible {
    struct Header: Decodable, Sendable { var name: String; var value: String }

    var id: GmailMessageID
    var threadID: GmailMessageID
    var labelIDs: [GmailLabelID]
    var historyID: UInt64?
    /// When Gmail received the message, in milliseconds since 1970.
    var internalDateMilliseconds: Int64?
    var sizeEstimate: Int64?
    /// The RFC 822 bytes, decoded from base64url. Only in `raw` format.
    var raw: Data?
    /// Header fields, only in `metadata` format.
    var headers: [Header]

    enum CodingKeys: String, CodingKey {
        case id, labelIds, historyId, internalDate, sizeEstimate, raw, payload
        case threadID = "threadId"
    }

    private struct Payload: Decodable { var headers: [Header]? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(GmailMessageID.self, forKey: .id)
        threadID = try container.decode(GmailMessageID.self, forKey: .threadID)
        labelIDs = try container.decodeIfPresent([GmailLabelID].self, forKey: .labelIds) ?? []
        historyID = container.contains(.historyId) ? try GmailNumber.decode(container, .historyId) : nil
        internalDateMilliseconds = container.contains(.internalDate) ? Int64(try GmailNumber.decode(container, .internalDate)) : nil
        sizeEstimate = try container.decodeIfPresent(Int64.self, forKey: .sizeEstimate)
        if let text = try container.decodeIfPresent(String.self, forKey: .raw) {
            guard let bytes = OAuthClient.base64URLDecode(text) else {
                throw DecodingError.dataCorruptedError(forKey: .raw, in: container, debugDescription: "raw is not base64url")
            }
            raw = bytes
        } else {
            raw = nil
        }
        headers = try container.decodeIfPresent(Payload.self, forKey: .payload)?.headers ?? []
    }

    var internalDate: Date? { internalDateMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    var description: String {
        "GmailMessage(\(id), labels: \(labelIDs.count), size: \(sizeEstimate.map(String.init) ?? "?"), raw: \(raw.map { "\($0.count) bytes" } ?? "none"))"
    }
}

/// One page of `users.history.list`.
struct GmailHistoryList: Decodable, Sendable {
    struct Change: Decodable, Sendable {
        var message: GmailMessageRef
        /// For label changes: the labels added or removed.
        var labelIDs: [GmailLabelID]

        enum CodingKeys: String, CodingKey { case message, labelIds }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decode(GmailMessageRef.self, forKey: .message)
            labelIDs = try container.decodeIfPresent([GmailLabelID].self, forKey: .labelIds) ?? []
        }
    }

    struct Record: Decodable, Sendable {
        var id: UInt64
        var messagesAdded: [Change]
        var messagesDeleted: [Change]
        var labelsAdded: [Change]
        var labelsRemoved: [Change]

        enum CodingKeys: String, CodingKey { case id, messagesAdded, messagesDeleted, labelsAdded, labelsRemoved }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try GmailNumber.decode(container, .id)
            messagesAdded = try container.decodeIfPresent([Change].self, forKey: .messagesAdded) ?? []
            messagesDeleted = try container.decodeIfPresent([Change].self, forKey: .messagesDeleted) ?? []
            labelsAdded = try container.decodeIfPresent([Change].self, forKey: .labelsAdded) ?? []
            labelsRemoved = try container.decodeIfPresent([Change].self, forKey: .labelsRemoved) ?? []
        }
    }

    var history: [Record]
    var nextPageToken: String?
    /// The mailbox's current history ID; stored once the last page is read.
    var historyID: UInt64

    enum CodingKeys: String, CodingKey {
        case history, nextPageToken
        case historyID = "historyId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        history = try container.decodeIfPresent([Record].self, forKey: .history) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        historyID = try GmailNumber.decode(container, .historyID)
    }
}

/// Google sends 64-bit numbers (history IDs, `internalDate`) as JSON strings.
/// Accepts a plain JSON number as well.
enum GmailNumber {
    static func decode<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws -> UInt64 {
        if let text = try? container.decode(String.self, forKey: key) {
            guard let value = UInt64(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not a number")
            }
            return value
        }
        return try container.decode(UInt64.self, forKey: key)
    }
}

/// Google's error body: `{"error": {"code": 403, "status": "...", "errors": [{"reason": "..."}]}}`.
/// Only the reason codes are kept; Google's free-text `message` is dropped.
struct GmailErrorBody: Decodable {
    struct Detail: Decodable { var reason: String? }
    struct Inner: Decodable {
        var code: Int?
        var status: String?
        var errors: [Detail]?
        var details: [Detail]?
    }

    var error: Inner?

    /// Reason codes from Google's error pages. Anything else is shown as
    /// `other`, so a reply can never put its own text into an error or log line.
    static let knownReasons: Set<String> = [
        "authError", "badRequest", "invalid", "invalidArgument", "failedPrecondition", "notFound", "forbidden",
        "rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded", "quotaExceeded", "domainPolicy",
        "accessNotConfigured", "insufficientPermissions", "backendError",
        "ACCESS_TOKEN_SCOPE_INSUFFICIENT", "SERVICE_DISABLED", "UNAUTHENTICATED", "PERMISSION_DENIED",
        "RESOURCE_EXHAUSTED", "NOT_FOUND", "INVALID_ARGUMENT", "FAILED_PRECONDITION", "INTERNAL", "UNAVAILABLE",
    ]

    /// The first reason code, if it is one Google documents.
    static func reason(in body: Data) -> String? {
        guard let inner = (try? JSONDecoder().decode(GmailErrorBody.self, from: body))?.error else { return nil }
        guard let raw = inner.errors?.compactMap(\.reason).first ?? inner.details?.compactMap(\.reason).first ?? inner.status
        else { return nil }
        return knownReasons.contains(raw) ? raw : "other"
    }
}
