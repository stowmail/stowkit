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
    /// Stow tried to read its text and could not (D-481): `unsupported` or
    /// `ocr_failed` because reading failed, not because Stow does not read the
    /// type. Stow tries again after an update.
    public var textUnreadable: Bool

    public init(index: Int, filename: String?, mimeType: String?, size: Int, disposition: String?, textStatus: String,
                textLength: Int, textUnreadable: Bool = false) {
        self.index = index
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.disposition = disposition
        self.textStatus = textStatus
        self.textLength = textLength
        self.textUnreadable = textUnreadable
    }

    enum CodingKeys: String, CodingKey {
        case index, filename, mimeType, size, disposition, textStatus, textLength, textUnreadable
    }

    /// `textUnreadable` decodes as false when missing, so a value encoded before D-481's mark still reads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(index: try c.decode(Int.self, forKey: .index), filename: try c.decodeIfPresent(String.self, forKey: .filename),
                  mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType), size: try c.decode(Int.self, forKey: .size),
                  disposition: try c.decodeIfPresent(String.self, forKey: .disposition),
                  textStatus: try c.decode(String.self, forKey: .textStatus), textLength: try c.decode(Int.self, forKey: .textLength),
                  textUnreadable: try c.decodeIfPresent(Bool.self, forKey: .textUnreadable) ?? false)
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
    /// The folders and Gmail labels the provider has this message in now (R11): copies the
    /// server no longer has are left out, so a deleted or spam message has none. Gmail's All
    /// Mail is included as stored; the app names and filters them as its sidebar does.
    public var places: [ArchiveFolder]
    /// When Stow stored the message (`messages.imported_at`, R11). Nil only when decoded from
    /// a value encoded before this field existed.
    public var importedAt: Date?
    /// When `sourceState` last changed (`messages.source_state_at`, D-039), for "Deleted from
    /// Gmail 1 Oct 2026" (UI-24). Nil while the message has always been present.
    public var sourceStateAt: Date?
    /// Stow could not read all of this email (D-481): its own text, or an
    /// attachment's (see `AttachmentInfo.textUnreadable`). It is stored whole and
    /// opens and exports as usual; search misses the part that was not read.
    /// Stow tries again after an update. A message whose own text was not read
    /// has no subject, sender or body here until then.
    public var textIncomplete: Bool
    /// The From address's domain appears in no From, To or Cc of an earlier message in this
    /// conversation (D-486, D-520): someone new joined it. Never set on the first message.
    /// A prompt to look twice, not a verdict.
    public var senderDomainNewToThread: Bool

    public init(messageID: StoredMessageID, accountID: AccountID, threadKey: String?, date: Date, sentDate: Date?,
                from: EmailAddress?, to: [EmailAddress], cc: [EmailAddress], subject: String?, sourceState: SourceState,
                body: String?, bodyFromHTML: Bool, bodyLength: Int, bodyTruncated: Bool, attachments: [AttachmentInfo],
                places: [ArchiveFolder] = [], importedAt: Date? = nil, sourceStateAt: Date? = nil, textIncomplete: Bool = false,
                senderDomainNewToThread: Bool = false) {
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
        self.places = places
        self.importedAt = importedAt
        self.sourceStateAt = sourceStateAt
        self.textIncomplete = textIncomplete
        self.senderDomainNewToThread = senderDomainNewToThread
    }

    enum CodingKeys: String, CodingKey {
        case messageID, accountID, threadKey, date, sentDate, from, to, cc, subject, sourceState, body, bodyFromHTML,
             bodyLength, bodyTruncated, attachments, places, importedAt, sourceStateAt, textIncomplete,
             senderDomainNewToThread
    }

    /// `places`, `importedAt`, `sourceStateAt`, `textIncomplete` and `senderDomainNewToThread` decode with defaults when missing, so a value
    /// encoded before R11 (or D-481's mark) still reads (as D-418 did for `SearchHit.sourceState`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(messageID: try c.decode(StoredMessageID.self, forKey: .messageID),
                  accountID: try c.decode(AccountID.self, forKey: .accountID),
                  threadKey: try c.decodeIfPresent(String.self, forKey: .threadKey),
                  date: try c.decode(Date.self, forKey: .date),
                  sentDate: try c.decodeIfPresent(Date.self, forKey: .sentDate),
                  from: try c.decodeIfPresent(EmailAddress.self, forKey: .from),
                  to: try c.decode([EmailAddress].self, forKey: .to),
                  cc: try c.decode([EmailAddress].self, forKey: .cc),
                  subject: try c.decodeIfPresent(String.self, forKey: .subject),
                  sourceState: try c.decode(SourceState.self, forKey: .sourceState),
                  body: try c.decodeIfPresent(String.self, forKey: .body),
                  bodyFromHTML: try c.decode(Bool.self, forKey: .bodyFromHTML),
                  bodyLength: try c.decode(Int.self, forKey: .bodyLength),
                  bodyTruncated: try c.decode(Bool.self, forKey: .bodyTruncated),
                  attachments: try c.decode([AttachmentInfo].self, forKey: .attachments),
                  places: try c.decodeIfPresent([ArchiveFolder].self, forKey: .places) ?? [],
                  importedAt: try c.decodeIfPresent(Date.self, forKey: .importedAt),
                  sourceStateAt: try c.decodeIfPresent(Date.self, forKey: .sourceStateAt),
                  textIncomplete: try c.decodeIfPresent(Bool.self, forKey: .textIncomplete) ?? false,
                  senderDomainNewToThread: try c.decodeIfPresent(Bool.self, forKey: .senderDomainNewToThread) ?? false)
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

/// One attachment's decoded bytes, for Quick Look and Save in the reader (D-410).
/// In memory only.
public struct AttachmentData: Hashable, Sendable, Codable {
    public var messageID: StoredMessageID
    public var info: AttachmentInfo
    public var data: Data

    public init(messageID: StoredMessageID, info: AttachmentInfo, data: Data) {
        self.messageID = messageID
        self.info = info
        self.data = data
    }
}

/// Reads an attachment's bytes by its 1-based index (the numbering of
/// `MessageDetail.attachments`), for the app's reader (D-410). Needs the file
/// key, so like `InlinePartReading` it is not part of `MessageReading` (D-405).
public protocol AttachmentDataReading: Sendable {
    /// The attachment decrypted into memory, or nil if there is no such message or index.
    /// Never writes a file; the caller decides where, if anywhere, it is saved.
    func attachmentData(message: StoredMessageID, index: Int) async throws -> AttachmentData?
}

/// A message's body as the reader shows it (D-059, R9): the HTML part as
/// decoded text, the plain part, or both, and the `cid:` references the HTML
/// makes. Rebuilt in memory from the stored message; nothing is written to
/// disk and nothing is fetched.
public struct MessageBody: Hashable, Sendable, Codable {
    public var messageID: StoredMessageID
    /// Every text/html body part, decoded with its charset, joined by a line break. Nil if none.
    /// Untrusted: show it only in a web view with scripts and network loads blocked.
    public var html: String?
    /// Every text/plain body part, decoded, joined by blank lines. Nil if none.
    public var plain: String?
    /// The Content-IDs the HTML refers to as `cid:...`, as `InlinePart.contentID(fromReference:)`
    /// gives them, in the order first seen, each once.
    public var contentIDs: [String]

    public init(messageID: StoredMessageID, html: String?, plain: String?, contentIDs: [String]) {
        self.messageID = messageID
        self.html = html
        self.plain = plain
        self.contentIDs = contentIDs
    }

    /// The Content-IDs of every `cid:` reference in `html` (in `src`, `href`,
    /// CSS `url()` or anywhere else), in order, each once.
    public static func contentIDs(inHTML html: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9])cid:[^\s"'<>()\\]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>()
        var found: [String] = []
        let text = html as NSString
        for match in expression.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let id = InlinePart.contentID(fromReference: text.substring(with: match.range))
            if !id.isEmpty, seen.insert(id).inserted { found.append(id) }
        }
        return found
    }
}

/// Reads a message's displayable body for the app's reader (D-059, R9, D-409).
///
/// Separate from `MessageReading` for the same reason as `InlinePartReading`:
/// the HTML is not in the database (only its text is), so the stored message
/// is decrypted and parsed again, which needs the file key.
public protocol MessageBodyReading: Sendable {
    /// The body of `message`, or nil if there is no such message.
    func body(of message: StoredMessageID) async throws -> MessageBody?
}
