import Foundation
import NIOIMAPCore
import StowCore

/// Where to connect. TLS is mandatory except on the loopback address, which
/// only the test server uses.
public struct IMAPEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let useTLS: Bool

    public init(host: String, port: Int = 993) {
        self.host = host
        self.port = port
        self.useTLS = true
    }

    /// A plain-text endpoint, allowed only on 127.0.0.1 (for the fake server in tests).
    public static func plaintextLoopback(port: Int) -> IMAPEndpoint {
        IMAPEndpoint(host: "127.0.0.1", port: port, useTLS: false)
    }

    private init(host: String, port: Int, useTLS: Bool) {
        precondition(useTLS || host == "127.0.0.1", "Plain-text IMAP is only allowed on 127.0.0.1")
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }

    public static let gmail = IMAPEndpoint(host: "imap.gmail.com")
    public static let office365 = IMAPEndpoint(host: "outlook.office365.com")
}

/// How long to wait before giving up on the server.
public struct IMAPTimeouts: Sendable {
    public var connect: TimeInterval
    /// Longest silence allowed while a reply is expected.
    public var read: TimeInterval

    public init(connect: TimeInterval = 30, read: TimeInterval = 90) {
        self.connect = connect
        self.read = read
    }

    public static let `default` = IMAPTimeouts()
}

/// One mailbox from LIST.
public struct IMAPFolder: Sendable, Hashable, CustomStringConvertible {
    /// The name decoded from modified UTF-7, joined with the server's separator.
    /// This is what goes into `RawMessageKey.folder` and checkpoints (D-111).
    public let name: String
    /// The exact bytes the server uses for this mailbox, sent back in EXAMINE.
    public let rawName: [UInt8]
    public let separator: Character?
    /// Attribute names, lowercased, for example `\noselect` or `\all`.
    public let attributes: Set<String>

    public init(name: String, rawName: [UInt8], separator: Character?, attributes: Set<String>) {
        self.name = name
        self.rawName = rawName
        self.separator = separator
        self.attributes = Set(attributes.map { $0.lowercased() })
    }

    public var isSelectable: Bool {
        !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent")
    }

    public func has(_ attribute: String) -> Bool { attributes.contains(attribute.lowercased()) }

    /// The special-use flag (RFC 6154), if any: `\All`, `\Junk`, `\Trash`, `\Sent`, ...
    public var specialUse: String? {
        let known = ["\\all", "\\archive", "\\drafts", "\\flagged", "\\junk", "\\sent", "\\trash", "\\important"]
        return known.first { attributes.contains($0) }
    }

    /// The folder as the sync state records it.
    public func syncFolder(skippedReason: String?) -> SyncFolder {
        SyncFolder(name: name, delimiter: separator.map(String.init), specialUse: specialUse,
                   isSelectable: isSelectable, skippedReason: skippedReason)
    }

    /// Folder names can be personal, so they are not printed by default.
    public var description: String {
        "IMAPFolder(\(attributes.sorted().joined(separator: " ")))"
    }
}

/// What EXAMINE says about a folder.
public struct FolderStatus: Sendable, Equatable {
    public var uidValidity: UInt32
    public var uidNext: UInt32?
    public var exists: Int
    /// HIGHESTMODSEQ, when the server supports CONDSTORE and it was asked for.
    public var highestModSeq: UInt64? = nil
}

/// A message's UID and size, from a cheap listing fetch.
public struct MessageSummary: Sendable, Equatable {
    public var uid: UInt32
    public var size: Int
    public var internalDate: Date? = nil
    /// Only filled in by the re-listing of specific UIDs.
    public var flags: [String] = []
    /// Gmail's permanent message ID, when listed from a Gmail account.
    public var gmailMessageID: UInt64? = nil
}

/// One message as fetched, before it is turned into a `RawMessage`.
public struct FetchedMessage: Sendable, Equatable {
    public var uid: UInt32
    /// RFC822.SIZE as the server reported it. Metadata and a budgeting estimate
    /// only: Exchange's value is not the exact byte count (D-120).
    public var size: Int
    public var internalDate: Date
    public var gmailMessageID: UInt64?
    public var gmailThreadID: UInt64?
    public var labels: [String]
    public var flags: [String] = []
    /// The complete message from BODY.PEEK[]. Never log it.
    public var bytes: Data
}

extension ServerMessageDate {
    /// The moment this date names, in absolute time.
    var date: Date? {
        let c = components
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: c.zoneMinutes * 60) else { return nil }
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second))
    }
}

/// How the server completed a message FETCH, for diagnosing partial replies
/// (D-118). Server text is scrubbed; nothing here holds message content.
public struct FetchDiagnostics: Sendable, Equatable {
    /// `OK` or `NO`.
    public var status: String
    /// The response code on the completion, for example `UNAVAILABLE`, if any.
    public var code: String?
    public var text: String = ""
    /// Untagged NO, BAD or BYE lines received during the command.
    public var untagged: [String] = []
}

/// The storage quota a server reports for a mailbox's quota root (R6, D-404).
/// Gmail's is the whole Google account's storage, shared with Drive and Photos.
public struct MailboxQuota: Sendable, Equatable {
    /// What the quota root uses now, in bytes.
    public var usedBytes: Int64
    /// The limit, in bytes.
    public var limitBytes: Int64

    public init(usedBytes: Int64, limitBytes: Int64) {
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
    }
}
