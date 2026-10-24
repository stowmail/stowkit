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
