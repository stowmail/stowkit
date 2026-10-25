import Foundation

/// One attachment of a message, without its bytes (D-081).
public struct AttachmentInfo: Hashable, Sendable, Codable {
    /// 1-based position among the message's attachments, in MIME part order.
    public var index: Int
    public var filename: String?
    /// The detected type, else the type the message declared.
    public var mimeType: String?
    /// Decoded size in bytes.
    public var size: Int
    /// `attachment` or `inline`, as the message declared it.
    public var disposition: String?
    /// Whether text could be read from it: `none`, `extracted`, `ocr_pending`, `ocr_done`, `ocr_failed`, `unsupported`.
    public var textStatus: String
    /// Length of the extracted text in characters (Unicode scalars), 0 if none.
    public var textLength: Int

    public init(index: Int, filename: String?, mimeType: String?, size: Int, disposition: String?, textStatus: String,
                textLength: Int) {
        self.index = index
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.disposition = disposition
        self.textStatus = textStatus
        self.textLength = textLength
    }
}

/// A stored message as text: headers that matter to a reader, the body and the
/// attachment list (D-081). The body is cut to the length asked for.
public struct MessageDetail: Hashable, Sendable, Codable, Identifiable {
    public var id: StoredMessageID { messageID }

    public var messageID: StoredMessageID
    public var accountID: AccountID
    public var threadKey: String?
    /// The server's arrival time (`internal_date`), as the list and threads use.
    public var date: Date
    /// The Date header, if it had a usable one.
    public var sentDate: Date?
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var subject: String?
    public var sourceState: SourceState
    /// The plain text part, else text taken from the HTML part; nil if the message has neither.
    /// At most the number of characters asked for.
    public var body: String?
    /// True when `body` came from HTML.
    public var bodyFromHTML: Bool
    /// The whole body's length in characters (Unicode scalars, as SQLite counts), even when `body` is cut.
    public var bodyLength: Int
    /// True when `body` is only the start of the body.
    public var bodyTruncated: Bool
    public var attachments: [AttachmentInfo]

    public init(messageID: StoredMessageID, accountID: AccountID, threadKey: String?, date: Date, sentDate: Date?,
                from: EmailAddress?, to: [EmailAddress], cc: [EmailAddress], subject: String?, sourceState: SourceState,
                body: String?, bodyFromHTML: Bool, bodyLength: Int, bodyTruncated: Bool, attachments: [AttachmentInfo]) {
        self.messageID = messageID
        self.accountID = accountID
        self.threadKey = threadKey
        self.date = date
        self.sentDate = sentDate
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.sourceState = sourceState
        self.body = body
        self.bodyFromHTML = bodyFromHTML
        self.bodyLength = bodyLength
        self.bodyTruncated = bodyTruncated
        self.attachments = attachments
    }
}

/// The text extracted from one attachment (PDFKit, .docx, plain text or OCR), never its bytes (D-081).
public struct AttachmentText: Hashable, Sendable, Codable {
    public var messageID: StoredMessageID
    public var accountID: AccountID
    public var info: AttachmentInfo
    /// `plain`, `pdfkit`, `docx` or `ocr`; nil when there is no text.
    public var method: String?
    /// The characters from `offset`, at most the number asked for; nil when there is no text.
    public var text: String?
    /// Where `text` starts in the whole extracted text, in characters.
    public var offset: Int
    /// True when more text follows `text`.
    public var hasMore: Bool { offset + (text?.unicodeScalars.count ?? 0) < info.textLength }

    public init(messageID: StoredMessageID, accountID: AccountID, info: AttachmentInfo, method: String?, text: String?, offset: Int) {
        self.messageID = messageID
        self.accountID = accountID
        self.info = info
        self.method = method
        self.text = text
        self.offset = offset
    }
}

/// Reads stored messages as text. Implemented by `StowSearch` (`MessageReader`);
/// used by MCP (Phase 3) and the app's reader.
public protocol MessageReading: Sendable {
    /// A message with at most `bodyLimit` characters of its body, or nil if there is no such message.
    func message(_ id: StoredMessageID, bodyLimit: Int) async throws -> MessageDetail?
    /// Up to `limit` characters of an attachment's extracted text from `offset`,
    /// by its 1-based index in the message; nil if there is no such message or attachment.
    func attachmentText(message: StoredMessageID, index: Int, offset: Int, limit: Int) async throws -> AttachmentText?
}

/// One MIME part of a stored message found by its Content-ID: an image the
/// HTML refers to as `cid:...` (D-059, R8). Decoded bytes, in memory only.
public struct InlinePart: Hashable, Sendable {
    public var messageID: StoredMessageID
    /// The Content-ID, without angle brackets.
    public var contentID: String
    /// The part's decoded content.
    public var data: Data
    /// The type the message declared for the part, lowercased, for example `image/png`.
    public var declaredType: String
    /// The type Stow detected when it stored the part, if it could tell.
    public var detectedType: String?
    public var filename: String?

    public init(messageID: StoredMessageID, contentID: String, data: Data, declaredType: String, detectedType: String?,
                filename: String?) {
        self.messageID = messageID
        self.contentID = contentID
        self.data = data
        self.declaredType = declaredType
        self.detectedType = detectedType
        self.filename = filename
    }

    /// The Content-ID a `cid:` reference names: `cid:` taken off, percent
    /// escapes decoded (RFC 2392) and angle brackets removed. Also accepts a bare ID.
    public static func contentID(fromReference reference: String) -> String {
        var text = reference.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("cid:") {
            text = String(text.dropFirst(4))
            text = text.removingPercentEncoding ?? text
        }
        if text.hasPrefix("<"), text.hasSuffix(">"), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
        return text
    }
}

/// Reads a message's inline parts by Content-ID, for the app's reader (D-059, R8).
///
/// Separate from `MessageReading` because it opens the encrypted attachment
/// files, which needs the file key: the MCP server reads the database alone
/// and never loads that key (D-081), so it does not offer this (D-405).
public protocol InlinePartReading: Sendable {
    /// The part of `message` whose Content-ID matches, decoded; nil if the
    /// message or the ID is unknown. Never fetches anything from the network.
    func inlinePart(message: StoredMessageID, contentID: String) async throws -> InlinePart?
}
