import Foundation
import NIOIMAPCore

/// Builds messages from the streamed parts of FETCH replies.
///
/// Sizes and literal lengths come from the server, so they are bounded before
/// use: a hostile or broken server must not be able to trap an addition or a
/// memory reservation (security review M-4, M-5). A response for a UID that
/// was not asked for is counted and dropped as it arrives, its bytes never
/// kept, and every streamed byte counts towards `byteLimit` (A-13, D-496).
struct FetchAssembler {
    /// The UIDs a command asked for.
    enum Wanted {
        case range(ClosedRange<UInt32>)
        case uids(Set<UInt32>)

        func contains(_ uid: UInt32) -> Bool {
            switch self {
            case .range(let range): range.contains(uid)
            case .uids(let uids): uids.contains(uid)
            }
        }
    }

    /// RFC822.SIZE values above this are taken as this. Far above any real
    /// message (the parser refuses bodies over `IMAPConnection.bodySizeLimit`),
    /// and small enough that adding millions of them cannot overflow.
    static let maximumReportedSize = 1 << 40
    /// The most memory reserved up front for a body; larger bodies grow as they arrive.
    static let maximumReservation = 32 << 20

    struct Partial {
        var uid: UInt32?
        var size: Int?
        var internalDate: Date?
        var gmailMessageID: UInt64?
        var gmailThreadID: UInt64?
        var labels: [String] = []
        var flags: [String] = []
        var modSeq: UInt64?
        var body: Data?
        /// The literal length the server announced for the body.
        var announcedBodyLength: Int?
        /// `BODY[HEADER.FIELDS (...)]`, when that was asked for.
        var headerFields: Data?
    }

    private enum Streaming {
        case none
        case body
        case headerFields
    }

    private(set) var finished: [Partial] = []
    private(set) var dropped = 0
    private(set) var bytes = 0
    private var current: Partial?
    private var streaming = Streaming.none
    let wanted: Wanted?
    let byteLimit: Int

    init(wanted: Wanted? = nil, byteLimit: Int = IMAPSession.nonBodyReplyBytes) {
        self.wanted = wanted
        self.byteLimit = byteLimit
    }

    /// False once the current response's UID is known and was not asked for.
    private var keepingCurrent: Bool {
        guard let wanted, let uid = current?.uid else { return true }
        return wanted.contains(uid)
    }

    mutating func consume(_ response: Response) throws {
        guard case .fetch(let part) = response else { return }
        switch part {
        case .start, .startUID(_):
            current = Partial()
            if case .startUID(let uid) = part { current?.uid = uid.rawValue }
        case .simpleAttribute(let attribute):
            switch attribute {
            case .uid(let uid): current?.uid = uid.rawValue
            case .rfc822Size(let size): current?.size = min(max(size, 0), Self.maximumReportedSize)
            case .internalDate(let date): current?.internalDate = date.date
            case .gmailMessageID(let id): current?.gmailMessageID = id
            case .gmailThreadID(let id): current?.gmailThreadID = id
            case .gmailLabels(let labels): current?.labels = labels.map { $0.makeDisplayString() }
            case .flags(let flags): current?.flags = flags.map { String($0) }
            case .fetchModificationSequence(let value): current?.modSeq = UInt64(value)
            case .nilBody(.body(section: let section, offset: nil)) where Self.isHeaderFields(section):
                current?.headerFields = Data()
            default: break
            }
        case .streamingBegin(let kind, let byteCount):
            switch kind {
            case .body(section: let section, offset: nil) where section == .complete:
                streaming = .body
                current?.body = Data(capacity: min(byteCount, Self.maximumReservation))
                current?.announcedBodyLength = byteCount
            case .body(section: let section, offset: nil) where Self.isHeaderFields(section):
                streaming = .headerFields
                current?.headerFields = Data(capacity: min(byteCount, Self.maximumReservation))
            case .rfc822:
                streaming = .body
                current?.body = Data(capacity: min(byteCount, Self.maximumReservation))
                current?.announcedBodyLength = byteCount
            default:
                streaming = .none
            }
        case .streamingBytes(let buffer):
            bytes += buffer.readableBytes
            guard bytes <= byteLimit else {
                throw SyncError.connectionClosed("FETCH reply passed its byte limit of \(byteLimit >> 20) MB")
            }
            guard keepingCurrent else { return }
            switch streaming {
            case .body: current?.body?.append(contentsOf: buffer.readableBytesView)
            case .headerFields: current?.headerFields?.append(contentsOf: buffer.readableBytesView)
            case .none: break
            }
        case .streamingEnd:
            streaming = .none
        case .finish:
            if let current {
                if let wanted, !(current.uid.map(wanted.contains) ?? false) {
                    dropped += 1
                } else {
                    finished.append(current)
                }
            }
            current = nil
        }
    }

    static func isHeaderFields(_ section: SectionSpecifier) -> Bool {
        guard [Int](section.part).isEmpty, case .headerFields = section.kind else { return false }
        return true
    }
}
