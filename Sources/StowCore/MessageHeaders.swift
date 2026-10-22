import Foundation

/// One header field exactly as it appeared in the message, after unfolding.
///
/// `value` is unfolded (continuation line breaks removed) but otherwise raw:
/// RFC 2047 encoded words are left encoded, so nothing is lost.
public struct HeaderField: Hashable, Sendable, Codable {
    /// Field name as written, for example "List-Unsubscribe". Compare case-insensitively.
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The parsed header set of one message: everything the rules engine needs,
/// and the fields storage indexes.
///
/// Typed properties are decoded (RFC 2047 words decoded, addresses split).
/// `fields` keeps every header in original order for anything the typed
/// properties do not cover, including the raw `List-*` and `Precedence` values.
///
/// Built by a `HeaderParsing` implementation (Track B, D-017). Tests can build
/// one directly with the memberwise initialiser.
public struct MessageHeaders: Hashable, Sendable, Codable {
    /// Every header field, in order, unfolded but not decoded.
    public var fields: [HeaderField]

    public var from: [EmailAddress]
    public var sender: EmailAddress?
    public var replyTo: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    /// Usually empty: only present on messages the user sent, or on badly behaved servers.
    public var bcc: [EmailAddress]
    /// `Delivered-To` and similar envelope hints, used to spot "user in BCC only".
    public var deliveredTo: [EmailAddress]

    /// Decoded subject. Never log it.
    public var subject: String?
    /// Parsed Date header. Nil when missing or malformed; see `dateRaw`.
    public var date: Date?
    /// The Date header as written, kept so malformed dates can be shown and re-parsed later.
    public var dateRaw: String?

    /// Message-ID without angle brackets. Nil when missing.
    public var messageID: String?
    public var inReplyTo: [String]
    public var references: [String]

    // Bulk-mail signals (Track C).
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
    public var listID: String?
    /// Lowercased value of `Precedence`, for example "bulk" or "list".
    public var precedence: String?
    /// Lowercased value of `Auto-Submitted`, for example "auto-generated".
    public var autoSubmitted: String?

    /// Problems found while parsing (for example "malformed Date"). Never contains header values.
    public var warnings: [String]

    public init(
        fields: [HeaderField] = [],
        from: [EmailAddress] = [],
        sender: EmailAddress? = nil,
        replyTo: [EmailAddress] = [],
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        deliveredTo: [EmailAddress] = [],
        subject: String? = nil,
        date: Date? = nil,
        dateRaw: String? = nil,
        messageID: String? = nil,
        inReplyTo: [String] = [],
        references: [String] = [],
        listUnsubscribe: String? = nil,
        listUnsubscribePost: String? = nil,
        listID: String? = nil,
        precedence: String? = nil,
        autoSubmitted: String? = nil,
        warnings: [String] = []
    ) {
        self.fields = fields
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.deliveredTo = deliveredTo
        self.subject = subject
        self.date = date
        self.dateRaw = dateRaw
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.listID = listID
        self.precedence = precedence
        self.autoSubmitted = autoSubmitted
        self.warnings = warnings
    }

    /// All raw values of a field, matched case-insensitively.
    public func values(named name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// The first raw value of a field, matched case-insensitively.
    public func value(named name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Number of distinct recipients across To, Cc and Bcc.
    public var recipientCount: Int {
        Set((to + cc + bcc).map(\.normalised)).count
    }
}

/// Turns the header block of a raw message into `MessageHeaders`.
///
/// Implemented by Track B in `StowCore` so that both storage and the rules
/// engine can use it without depending on each other (D-017). Must never
/// crash on malformed input: it degrades and records a warning instead.
public protocol HeaderParsing: Sendable {
    func parseHeaders(_ raw: Data) throws -> MessageHeaders
}
