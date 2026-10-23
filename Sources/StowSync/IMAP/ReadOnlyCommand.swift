import NIOCore
import NIOIMAPCore

/// The complete list of IMAP commands Stow can send (D-109).
///
/// This is the only way `IMAPSession` builds a command, and the connection
/// only accepts values of this type, so a command that changes the mailbox
/// (SELECT, STORE, EXPUNGE, MOVE, COPY, APPEND, DELETE, ...) cannot be sent:
/// there is no case for it. Messages are opened with EXAMINE (read-only) and
/// downloaded with BODY.PEEK[], which does not set the \Seen flag.
enum ReadOnlyCommand: Sendable {
    case capability
    case authenticateXOAUTH2(user: String, accessToken: String)
    /// `LIST "" "*"`: every mailbox.
    case listAll
    case examine(rawName: [UInt8])
    /// `UID FETCH lo:hi (UID RFC822.SIZE)`: what exists, and how big, without downloading.
    case fetchSummaries(ClosedRange<UInt32>)
    /// `UID FETCH <set> (UID RFC822.SIZE FLAGS INTERNALDATE)`: which of these
    /// UIDs still exist, with enough detail to record any that cannot be fetched.
    /// Fetching FLAGS only reads them.
    case fetchSummariesOf(uids: [UInt32])
    /// `UID FETCH <set> (UID RFC822.SIZE INTERNALDATE BODY.PEEK[] [X-GM-MSGID X-GM-THRID X-GM-LABELS])`.
    case fetchMessages(uids: [UInt32], gmail: Bool)
    case logout

    /// The command verb, for logs. Never includes arguments, which may hold a
    /// token or a folder name.
    var verb: String {
        switch self {
        case .capability: "CAPABILITY"
        case .authenticateXOAUTH2: "AUTHENTICATE XOAUTH2"
        case .listAll: "LIST"
        case .examine: "EXAMINE"
        case .fetchSummaries, .fetchSummariesOf, .fetchMessages: "UID FETCH"
        case .logout: "LOGOUT"
        }
    }

    /// The swift-nio-imap command this case stands for.
    var command: Command {
        switch self {
        case .capability:
            return .capability
        case .authenticateXOAUTH2(let user, let accessToken):
            return .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(ByteBuffer(bytes: XOAUTH2.initialResponse(user: user, accessToken: accessToken)))
            )
        case .listAll:
            return .list(nil, reference: MailboxName(Array("".utf8)), .mailbox(ByteBuffer(string: "*")), [])
        case .examine(let rawName):
            return .examine(MailboxName(rawName), [])
        case .fetchSummaries(let range):
            return .uidFetch(.range(Self.uidRange(range)), [.uid, .rfc822Size], [])
        case .fetchSummariesOf(let uids):
            return .uidFetch(.set(Self.uidSet(uids)), [.uid, .rfc822Size, .flags, .internalDate], [])
        case .fetchMessages(let uids, let gmail):
            var attributes: [FetchAttribute] = [.uid, .rfc822Size, .internalDate, .bodySection(peek: true, .complete, nil)]
            if gmail { attributes += [.gmailMessageID, .gmailThreadID, .gmailLabels] }
            return .uidFetch(.set(Self.uidSet(uids)), attributes, [])
        case .logout:
            return .logout
        }
    }

    static func uidRange(_ range: ClosedRange<UInt32>) -> MessageIdentifierRange<UID> {
        MessageIdentifierRange<UID>(UID(rawValue: max(range.lowerBound, 1))...UID(rawValue: max(range.upperBound, 1)))
    }

    /// Collapses sorted UIDs into ranges, for example 1,2,3,7 into 1:3,7.
    static func uidSet(_ uids: [UInt32]) -> MessageIdentifierSetNonEmpty<UID> {
        precondition(!uids.isEmpty, "fetchMessages needs at least one UID")
        var ranges: [ClosedRange<UInt32>] = []
        for uid in Set(uids).sorted() {
            if let last = ranges.last, last.upperBound &+ 1 == uid {
                ranges[ranges.count - 1] = last.lowerBound...uid
            } else {
                ranges.append(uid...uid)
            }
        }
        let set = MessageIdentifierSet<UID>(ranges.map { MessageIdentifierRange<UID>(UID(rawValue: $0.lowerBound)...UID(rawValue: $0.upperBound)) })
        return MessageIdentifierSetNonEmpty(set: set)!
    }
}

/// The SASL XOAUTH2 initial response used by Gmail and Outlook.
enum XOAUTH2 {
    /// `user=<address>^Aauth=Bearer <token>^A^A`. swift-nio-imap base64-encodes it.
    /// Contains the access token: never log it.
    static func initialResponse(user: String, accessToken: String) -> [UInt8] {
        Array("user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8)
    }
}
