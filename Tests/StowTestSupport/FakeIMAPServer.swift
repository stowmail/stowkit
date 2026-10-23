import Foundation
import Network

/// A small scripted IMAP server on 127.0.0.1 for tests. Plain text (the
/// session only allows plain text on loopback). It understands just the
/// commands Stow sends and records every command line it receives, so tests
/// can check that nothing but read-only commands ever reaches a server.
///
/// All state lives on `queue`; tests read it through the accessors.
///
/// Phase 2 additions: CONDSTORE (`EXAMINE ... (CONDSTORE)` answers
/// HIGHESTMODSEQ, `(CHANGEDSINCE n)` filters by each message's `modSeq`),
/// `BODY.PEEK[HEADER.FIELDS (...)]`, and FLAGS with downloads.
public final class FakeIMAPServer: @unchecked Sendable {
    public struct Message {
        public var uid: UInt32
        public var bytes: Data
        public var labels: [String]
        public var gmailMessageID: UInt64
        public var gmailThreadID: UInt64
        public var internalDate: String
        public var flags: [String]
        /// CONDSTORE mod-sequence: raise it whenever flags or labels change.
        public var modSeq: UInt64

        public init(uid: UInt32, bytes: Data, labels: [String] = [], gmailMessageID: UInt64 = 0, gmailThreadID: UInt64 = 0,
                    internalDate: String = "17-Jul-2024 02:44:25 -0700", flags: [String] = [], modSeq: UInt64 = 1) {
            self.uid = uid
            self.bytes = bytes
            self.labels = labels
            self.gmailMessageID = gmailMessageID
            self.gmailThreadID = gmailThreadID
            self.internalDate = internalDate
            self.flags = flags
            self.modSeq = modSeq
        }
    }

    public struct Mailbox {
        public var name: String
        public var attributes: [String]
        public var uidValidity: UInt32
        public var messages: [Message]
        /// Set to keep UIDNEXT above the highest UID, as after a deletion.
        public var uidNextOverride: UInt32?
        public var uidNext: UInt32 { uidNextOverride ?? ((messages.map(\.uid).max() ?? 0) + 1) }
        public var highestModSeq: UInt64 { messages.map(\.modSeq).max() ?? 1 }

        public init(name: String, attributes: [String], uidValidity: UInt32, messages: [Message], uidNextOverride: UInt32? = nil) {
            self.name = name
            self.attributes = attributes
            self.uidValidity = uidValidity
            self.messages = messages
            self.uidNextOverride = uidNextOverride
        }
    }

    // Configuration (set before or between connections).
    public var mailboxes: [Mailbox] { get { sync { _mailboxes } } set { sync { _mailboxes = newValue } } }
    public var capabilities: [String] { get { sync { _capabilities } } set { sync { _capabilities = newValue } } }
    public var acceptedTokens: Set<String> { get { sync { _acceptedTokens } } set { sync { _acceptedTokens = newValue } } }
    /// Drop the connection without replying when this many body fetches have been received (counted across connections).
    public var dropOnBodyFetchNumber: Int? { get { sync { _dropOn } } set { sync { _dropOn = newValue } } }
    /// Drop the connection on every body fetch.
    public var dropEveryBodyFetch: Bool { get { sync { _dropEvery } } set { sync { _dropEvery = newValue } } }
    /// Answer this body fetch (counted across connections) with BYE and close.
    public var byeOnBodyFetchNumber: (Int, String)? { get { sync { _byeOn } } set { sync { _byeOn = newValue } } }
    /// UIDs that are listed (and re-listed) but for which a body fetch returns no
    /// FETCH data at all, as Exchange does for calendar items.
    public var bodylessUIDs: Set<UInt32> { get { sync { _bodyless } } set { sync { _bodyless = newValue } } }
    /// UIDs deleted from the mailbox the moment a body fetch arrives, as if
    /// another client expunged them between listing and download.
    public var expungeOnBodyFetch: Set<UInt32> { get { sync { _expunge } } set { sync { _expunge = newValue } } }
    /// How many body fetches leave each UID out before it is returned (transient
    /// partial replies, as seen on Microsoft 365).
    public var refusals: [UInt32: Int] { get { sync { _refusals } } set { sync { _refusals = newValue } } }
    /// When a body fetch leaves anything out: the tagged completion to send
    /// instead of OK (for example "NO [UNAVAILABLE] Try later"), and an untagged line to add.
    public var partialCompletion: String? { get { sync { _partialCompletion } } set { sync { _partialCompletion = newValue } } }
    public var partialUntagged: String? { get { sync { _partialUntagged } } set { sync { _partialUntagged = newValue } } }
    /// Splits each message FETCH reply into separate writes, paced so they
    /// arrive as separate reads, at the offsets this returns (D-120).
    public var splitFetchReply: (@Sendable (Data) -> [Int])? { get { sync { _split } } set { sync { _split = newValue } } }
    /// Reported RFC822.SIZE for a message of the given length, in every reply,
    /// as Exchange does with its estimates. The literal length is always exact.
    public var reportedSize: (@Sendable (Int) -> Int)? { get { sync { _reportedSize } } set { sync { _reportedSize = newValue } } }
    /// Refuse every AUTHENTICATE at once with this text (no SASL challenge),
    /// as Exchange does for an account without a mailbox.
    public var authFailureText: String? { get { sync { _authFailure } } set { sync { _authFailure = newValue } } }
    /// Answer EXAMINE with READ-WRITE, to test that the session refuses it.
    public var examineAnswersReadWrite: Bool { get { sync { _readWrite } } set { sync { _readWrite = newValue } } }

    // Observations.
    public var commandLog: [String] { sync { _log } }
    public var connectionCount: Int { sync { _connections } }
    public var bodyFetchCount: Int { sync { _bodyFetches } }
    /// How many times each UID's body was sent.
    public var bodiesServed: [UInt32: Int] { sync { _served } }

    private let queue = DispatchQueue(label: "uk.getstow.tests.fake-imap")
    private var listener: NWListener?
    private var _mailboxes: [Mailbox] = []
    private var _capabilities = ["IMAP4rev1", "X-GM-EXT-1", "AUTH=XOAUTH2", "SASL-IR", "UIDPLUS"]
    private var _acceptedTokens: Set<String> = ["good-token"]
    private var _dropOn: Int?
    private var _byeOn: (Int, String)?
    private var _readWrite = false
    private var _dropEvery = false
    private var _authFailure: String?
    private var _refusals: [UInt32: Int] = [:]
    private var _split: (@Sendable (Data) -> [Int])?
    private var _reportedSize: (@Sendable (Int) -> Int)?
    private var _partialCompletion: String?
    private var _partialUntagged: String?
    private var _bodyless: Set<UInt32> = []
    private var _expunge: Set<UInt32> = []
    private var _log: [String] = []
    private var _connections = 0
    private var _bodyFetches = 0
    private var _served: [UInt32: Int] = [:]
    public private(set) var port: UInt16 = 0

    private func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    public init(mailboxes: [Mailbox] = []) {
        _mailboxes = mailboxes
    }

    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.claim() { continuation.resume() }
                case .failed(let error): if resumed.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
        return port
    }

    public func stop() {
        queue.sync { listener?.cancel() }
    }

    // MARK: Connection handling (on queue)

    /// Only touched on the server's queue.
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var selected: Int?
        var pendingAuthTag: String?
        var closed = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        _connections += 1
        let client = Client(connection)
        connection.start(queue: queue)
        send("* OK [CAPABILITY \(_capabilities.joined(separator: " "))] Fake IMAP ready\r\n", to: client)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !client.closed else { return }
            if let data { client.buffer.append(data) }
            while let range = client.buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: client.buffer[client.buffer.startIndex..<range.lowerBound], as: UTF8.self)
                client.buffer.removeSubrange(client.buffer.startIndex..<range.upperBound)
                self.handle(line, client)
                if client.closed { return }
            }
            if isComplete || error != nil {
                client.closed = true
                client.connection.cancel()
                return
            }
            self.receive(client)
        }
    }

    private func send(_ text: String, to client: Client) {
        send(Data(text.utf8), to: client)
    }

    private func send(_ data: Data, to client: Client) {
        guard !client.closed else { return }
        client.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Sends `data` cut at `cuts`, 15 ms apart, so each piece is its own read.
    private func sendInPieces(_ data: Data, cuts: [Int], to client: Client) {
        let bounds = ([0] + cuts.filter { $0 > 0 && $0 < data.count }.sorted() + [data.count])
        var delay = 0.0
        for index in 0..<(bounds.count - 1) where bounds[index] < bounds[index + 1] {
            let piece = data.subdata(in: bounds[index]..<bounds[index + 1])
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.send(piece, to: client) }
            delay += 0.015
        }
    }

    private func close(_ client: Client) {
        client.closed = true
        client.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private func handle(_ line: String, _ client: Client) {
        if let tag = client.pendingAuthTag {
            // The client's empty reply to our failure challenge.
            client.pendingAuthTag = nil
            send("\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n", to: client)
            return
        }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return }
        let tag = parts[0]
        var verb = parts[1].uppercased()
        var rest = parts.count > 2 ? parts[2] : ""
        if verb == "UID", let space = rest.firstIndex(of: " ") {
            verb = "UID " + rest[..<space].uppercased()
            rest = String(rest[rest.index(after: space)...])
        }
        _log.append(verb == "AUTHENTICATE" ? "\(tag) AUTHENTICATE \(rest.split(separator: " ").first ?? "") [redacted]" : line)

        switch verb {
        case "CAPABILITY":
            send("* CAPABILITY \(_capabilities.joined(separator: " "))\r\n\(tag) OK CAPABILITY completed\r\n", to: client)
        case "AUTHENTICATE":
            authenticate(tag: tag, rest: rest, client)
        case "LIST":
            var out = ""
            for mailbox in _mailboxes {
                out += "* LIST (\(mailbox.attributes.joined(separator: " "))) \"/\" \(Self.quote(mailbox.name))\r\n"
            }
            send(out + "\(tag) OK LIST completed\r\n", to: client)
        case "EXAMINE":
            var nameText = rest
            var condstore = false
            if rest.uppercased().hasSuffix(" (CONDSTORE)") {
                nameText = String(rest.dropLast(" (CONDSTORE)".count))
                condstore = true
            }
            let name = Self.unquote(nameText)
            let isInbox = name.uppercased() == "INBOX"
            guard let index = _mailboxes.firstIndex(where: { $0.name == name || (isInbox && $0.name.uppercased() == "INBOX") }) else {
                send("\(tag) NO [NONEXISTENT] No such mailbox\r\n", to: client)
                return
            }
            client.selected = index
            let mailbox = _mailboxes[index]
            var out = "* FLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen)\r\n"
            out += "* OK [PERMANENTFLAGS ()] Flags permitted.\r\n"
            out += "* OK [UIDVALIDITY \(mailbox.uidValidity)] UIDs valid.\r\n"
            out += "* \(mailbox.messages.count) EXISTS\r\n* 0 RECENT\r\n"
            out += "* OK [UIDNEXT \(mailbox.uidNext)] Predicted next UID.\r\n"
            if condstore { out += "* OK [HIGHESTMODSEQ \(mailbox.highestModSeq)] Highest\r\n" }
            out += "\(tag) OK [\(_readWrite ? "READ-WRITE" : "READ-ONLY")] EXAMINE completed\r\n"
            send(out, to: client)
        case "UID FETCH":
            fetch(tag: tag, rest: rest, client)
        case "LOGOUT":
            send("* BYE Logging out\r\n\(tag) OK LOGOUT completed\r\n", to: client)
            close(client)
        default:
            send("\(tag) BAD Command not supported by the fake server\r\n", to: client)
        }
    }

    private func authenticate(tag: String, rest: String, _ client: Client) {
        let pieces = rest.split(separator: " ")
        guard pieces.count == 2, pieces[0].uppercased() == "XOAUTH2",
              let decoded = Data(base64Encoded: String(pieces[1]))
        else {
            send("\(tag) BAD Malformed AUTHENTICATE\r\n", to: client)
            return
        }
        if let failure = _authFailure {
            send("\(tag) NO \(failure)\r\n", to: client)
            return
        }
        let text = String(decoding: decoded, as: UTF8.self)
        let token = text.components(separatedBy: "auth=Bearer ").last?.components(separatedBy: "\u{01}").first ?? ""
        let user = text.components(separatedBy: "user=").last?.components(separatedBy: "\u{01}").first ?? ""
        if _acceptedTokens.contains(token), user.contains("@") {
            send("\(tag) OK [CAPABILITY \(_capabilities.joined(separator: " "))] user authenticated (Success)\r\n", to: client)
        } else {
            client.pendingAuthTag = tag
            let challenge = Data(#"{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}"#.utf8).base64EncodedString()
            send("+ \(challenge)\r\n", to: client)
        }
    }

    private func fetch(tag: String, rest: String, _ client: Client) {
        guard let selected = client.selected else {
            send("\(tag) BAD No mailbox selected\r\n", to: client)
            return
        }
        var mailbox = _mailboxes[selected]
        guard let space = rest.firstIndex(of: " ") else {
            send("\(tag) BAD Malformed FETCH\r\n", to: client)
            return
        }
        let set = String(rest[..<space])
        let original = String(rest[rest.index(after: space)...])
        let attributes = original.uppercased()
        let wantsBody = attributes.contains("BODY.PEEK[]")
        let headerFields = Self.headerFieldList(original)
        let changedSince = Self.changedSince(attributes)
        if attributes.contains("BODY[]") || attributes.contains("RFC822 ") || attributes.contains("RFC822)") {
            send("\(tag) BAD The fake server refuses non-PEEK body fetches\r\n", to: client)
            return
        }
        if wantsBody {
            _bodyFetches += 1
            if _dropEvery || _dropOn == _bodyFetches {
                client.closed = true
                client.connection.cancel()
                return
            }
            if let (number, text) = _byeOn, _bodyFetches == number {
                send("* BYE \(text)\r\n", to: client)
                close(client)
                return
            }
        }
        if wantsBody, !_expunge.isEmpty {
            _mailboxes[selected].messages.removeAll { _expunge.contains($0.uid) }
            mailbox = _mailboxes[selected]
        }
        let maxUID = mailbox.messages.map(\.uid).max() ?? 0
        let wanted = Self.parseSet(set, maxUID: maxUID)
        var out = Data()
        var omitted = false
        for (index, message) in mailbox.messages.enumerated() where wanted(message.uid) {
            if let changedSince, message.modSeq <= changedSince { continue }
            if wantsBody, _bodyless.contains(message.uid) { omitted = true; continue }
            if wantsBody, let left = _refusals[message.uid], left > 0 {
                _refusals[message.uid] = left - 1
                omitted = true
                continue
            }
            let reportedSize = _reportedSize?(message.bytes.count) ?? message.bytes.count
            var items = ["UID \(message.uid)"]
            if attributes.contains("RFC822.SIZE") { items.append("RFC822.SIZE \(reportedSize)") }
            if attributes.contains(" FLAGS") {
                items.append("FLAGS (\(message.flags.joined(separator: " ")))")
            }
            if attributes.contains("INTERNALDATE") { items.append("INTERNALDATE \"\(message.internalDate)\"") }
            if attributes.contains("X-GM-MSGID") { items.append("X-GM-MSGID \(message.gmailMessageID)") }
            if attributes.contains("X-GM-THRID") { items.append("X-GM-THRID \(message.gmailThreadID)") }
            if attributes.contains("X-GM-LABELS") {
                let labels = message.labels.map { $0.hasPrefix("\\") ? $0 : Self.quote($0) }.joined(separator: " ")
                items.append("X-GM-LABELS (\(labels))")
            }
            if changedSince != nil { items.append("MODSEQ (\(message.modSeq))") }
            out.append(Data("* \(index + 1) FETCH (\(items.joined(separator: " "))".utf8))
            if let headerFields {
                let fields = Self.headerFields(of: message.bytes, named: headerFields.names)
                out.append(Data(" BODY[HEADER.FIELDS (\(headerFields.text))] {\(fields.count)}\r\n".utf8))
                out.append(fields)
            }
            if wantsBody {
                out.append(Data(" BODY[] {\(message.bytes.count)}\r\n".utf8))
                out.append(message.bytes)
                _served[message.uid, default: 0] += 1
            }
            out.append(Data(")\r\n".utf8))
        }
        if omitted, let untagged = _partialUntagged { out.append(Data("* \(untagged)\r\n".utf8)) }
        if omitted, let completion = _partialCompletion {
            out.append(Data("\(tag) \(completion)\r\n".utf8))
        } else {
            out.append(Data("\(tag) OK UID FETCH completed\r\n".utf8))
        }
        if wantsBody, let split = _split {
            sendInPieces(out, cuts: split(out), to: client)
        } else {
            send(out, to: client)
        }
    }

    /// The field list of a `BODY.PEEK[HEADER.FIELDS (...)]` request, as sent and as names.
    static func headerFieldList(_ attributes: String) -> (text: String, names: [String])? {
        guard let start = attributes.range(of: "HEADER.FIELDS (", options: .caseInsensitive),
              let end = attributes[start.upperBound...].firstIndex(of: ")") else { return nil }
        let text = String(attributes[start.upperBound..<end])
        return (text, text.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) })
    }

    static func changedSince(_ attributes: String) -> UInt64? {
        guard let range = attributes.range(of: "CHANGEDSINCE ") else { return nil }
        return UInt64(attributes[range.upperBound...].prefix { $0.isNumber })
    }

    /// The named header fields of a message, as raw lines, then a blank line (RFC 3501).
    public static func headerFields(of message: Data, named names: [String]) -> Data {
        let wanted = Set(names.map { $0.lowercased() })
        let text = String(decoding: message, as: UTF8.self)
        let header = text.components(separatedBy: "\r\n\r\n").first ?? text
        var output = ""
        var keeping = false
        for line in header.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if keeping { output += line + "\r\n" }
                continue
            }
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            keeping = wanted.contains(name)
            if keeping { output += line + "\r\n" }
        }
        return Data((output + "\r\n").utf8)
    }

    /// Parses an IMAP sequence set such as `1:3,7,9:*` into a membership test.
    static func parseSet(_ text: String, maxUID: UInt32) -> (UInt32) -> Bool {
        func value(_ part: Substring) -> UInt32 {
            part == "*" ? maxUID : (UInt32(part) ?? 0)
        }
        var ranges: [ClosedRange<UInt32>] = []
        for piece in text.split(separator: ",") {
            let bounds = piece.split(separator: ":")
            let a = value(bounds[0]), b = bounds.count > 1 ? value(bounds[1]) : a
            // "n:*" with n above the highest UID still means the highest message (RFC 3501).
            let low = min(a, b), high = max(a, b)
            ranges.append(low...high)
        }
        return { uid in ranges.contains { $0.contains(uid) } }
    }

    public static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else { return trimmed }
        var result = ""
        var escaping = false
        for character in trimmed.dropFirst().dropLast() {
            if escaping { result.append(character); escaping = false }
            else if character == "\\" { escaping = true }
            else { result.append(character) }
        }
        return result
    }
}

/// Lets exactly one caller through, for resuming a continuation once.
public final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    public init() {}

    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
