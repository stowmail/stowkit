import NIOCore
import NIOIMAPCore

/// Which UIDs a command is about.
enum UIDSelection: Sendable, Equatable {
    case range(ClosedRange<UInt32>)
    case list([UInt32])

    var set: LastCommandSet<UID> {
        switch self {
        case .range(let range): .range(ReadOnlyCommand.uidRange(range))
        case .list(let uids): .set(ReadOnlyCommand.uidSet(uids))
        }
    }
}

/// The complete list of IMAP commands Stow can send (D-109; GETQUOTAROOT added by D-404).
///
/// This is the only way `IMAPSession` builds a command, and the connection
/// only accepts values of this type, so a command that changes the mailbox
/// (SELECT, STORE, EXPUNGE, MOVE, COPY, APPEND, DELETE, ...) cannot be sent:
/// there is no case for it. Messages are opened with EXAMINE (read-only) and
/// downloaded with BODY.PEEK[], which does not set the \Seen flag. Fetching
/// FLAGS, labels or MODSEQ only reads them.
enum ReadOnlyCommand: Sendable {
    case capability
    case authenticateXOAUTH2(user: String, accessToken: String)
    /// `LIST "" "*"`: every mailbox.
    case listAll
    /// `EXAMINE <mailbox> [(CONDSTORE)]`: read-only; CONDSTORE asks for HIGHESTMODSEQ (D-038).
    case examine(rawName: [UInt8], condstore: Bool)
    /// `UID FETCH lo:hi (UID RFC822.SIZE INTERNALDATE [X-GM-MSGID])`: what exists, how big
    /// and when it arrived, without downloading.
    case fetchSummaries(ClosedRange<UInt32>, gmail: Bool)
    /// `UID FETCH <set> (UID RFC822.SIZE FLAGS INTERNALDATE)`: which of these
    /// UIDs still exist, with enough detail to record any that cannot be fetched.
    case fetchSummariesOf(uids: [UInt32])
    /// `UID FETCH <set> (UID BODY.PEEK[HEADER.FIELDS (...)])`: just the named
    /// header fields, to order downloads (D-028) or match by Message-ID (D-039).
    case fetchHeaderFields(UIDSelection, fields: [String])
    /// `UID FETCH <set> (UID RFC822.SIZE INTERNALDATE FLAGS BODY.PEEK[] [X-GM-MSGID X-GM-THRID X-GM-LABELS])`.
    case fetchMessages(uids: [UInt32], gmail: Bool)
    /// `UID FETCH lo:hi (UID FLAGS [X-GM-LABELS]) [(CHANGEDSINCE n)]`: flags and
    /// labels of messages already archived, all of them or only those changed
    /// since a CONDSTORE mod-sequence (D-038).
    case fetchStates(ClosedRange<UInt32>, gmail: Bool, changedSince: UInt64?)
    /// `UID FETCH 1:* (UID X-GM-MSGID)`: the Gmail IDs in a folder such as Spam
    /// or Bin, to classify messages that left All Mail. Identifiers only, never content (D-039).
    case fetchGmailIDs(ClosedRange<UInt32>)
    /// `GETQUOTAROOT <mailbox>` (RFC 2087, RFC 9208): reads the quota that applies
    /// to a mailbox, for "your mail uses 6.2 GB of 15 GB" (R6, D-404). Only reads.
    /// SETQUOTA, which changes a quota, has no case.
    case getQuotaRoot(rawName: [UInt8])
    case logout

    /// The command verb, for logs. Never includes arguments, which may hold a
    /// token or a folder name.
    var verb: String {
        switch self {
        case .capability: "CAPABILITY"
        case .authenticateXOAUTH2: "AUTHENTICATE XOAUTH2"
        case .listAll: "LIST"
        case .examine: "EXAMINE"
        case .fetchSummaries, .fetchSummariesOf, .fetchHeaderFields, .fetchMessages, .fetchStates, .fetchGmailIDs: "UID FETCH"
        case .getQuotaRoot: "GETQUOTAROOT"
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
        case .examine(let rawName, let condstore):
            return .examine(MailboxName(rawName), condstore ? [.condStore] : [])
        case .fetchSummaries(let range, let gmail):
            var attributes: [FetchAttribute] = [.uid, .rfc822Size, .internalDate]
            if gmail { attributes.append(.gmailMessageID) }
            return .uidFetch(.range(Self.uidRange(range)), attributes, [])
        case .fetchSummariesOf(let uids):
            return .uidFetch(.set(Self.uidSet(uids)), [.uid, .rfc822Size, .flags, .internalDate], [])
        case .fetchHeaderFields(let selection, let fields):
            return .uidFetch(selection.set, [.uid, .bodySection(peek: true, SectionSpecifier(kind: .headerFields(fields)), nil)], [])
        case .fetchMessages(let uids, let gmail):
            var attributes: [FetchAttribute] = [.uid, .rfc822Size, .internalDate, .flags, .bodySection(peek: true, .complete, nil)]
            if gmail { attributes += [.gmailMessageID, .gmailThreadID, .gmailLabels] }
            return .uidFetch(.set(Self.uidSet(uids)), attributes, [])
        case .fetchStates(let range, let gmail, let changedSince):
            var attributes: [FetchAttribute] = [.uid, .flags]
            if gmail { attributes.append(.gmailLabels) }
            let modifiers: [FetchModifier] = changedSince.map {
                [.changedSince(ChangedSinceModifier(modificationSequence: ModificationSequenceValue($0)))]
            } ?? []
            return .uidFetch(.range(Self.uidRange(range)), attributes, modifiers)
        case .fetchGmailIDs(let range):
            return .uidFetch(.range(Self.uidRange(range)), [.uid, .gmailMessageID], [])
        case .getQuotaRoot(let rawName):
            return .getQuotaRoot(MailboxName(rawName))
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
