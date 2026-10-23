import Foundation
import Network

/// A small scripted IMAP server on 127.0.0.1 for tests. Plain text (the
/// session only allows plain text on loopback). It understands just the
/// commands Stow sends and records every command line it receives, so tests
/// can check that nothing but read-only commands ever reaches a server.
///
/// All state lives on `queue`; tests read it through the accessors.
final class FakeIMAPServer: @unchecked Sendable {
    struct Message {
        var uid: UInt32
        var bytes: Data
        var labels: [String] = []
        var gmailMessageID: UInt64 = 0
        var gmailThreadID: UInt64 = 0
        var internalDate = "17-Jul-2024 02:44:25 -0700"
        var flags: [String] = []
    }

    struct Mailbox {
        var name: String
        var attributes: [String]
        var uidValidity: UInt32
        var messages: [Message]
        var uidNext: UInt32 { (messages.map(\.uid).max() ?? 0) + 1 }
    }

    // Configuration (set before or between connections).
    var mailboxes: [Mailbox] { get { sync { _mailboxes } } set { sync { _mailboxes = newValue } } }
    var capabilities: [String] { get { sync { _capabilities } } set { sync { _capabilities = newValue } } }
    var acceptedTokens: Set<String> { get { sync { _acceptedTokens } } set { sync { _acceptedTokens = newValue } } }
    /// Drop the connection without replying when this many body fetches have been received (counted across connections).
    var dropOnBodyFetchNumber: Int? { get { sync { _dropOn } } set { sync { _dropOn = newValue } } }
    /// Drop the connection on every body fetch.
    var dropEveryBodyFetch: Bool { get { sync { _dropEvery } } set { sync { _dropEvery = newValue } } }
    /// Answer this body fetch (counted across connections) with BYE and close.
    var byeOnBodyFetchNumber: (Int, String)? { get { sync { _byeOn } } set { sync { _byeOn = newValue } } }
    /// UIDs that are listed (and re-listed) but for which a body fetch returns no
    /// FETCH data at all, as Exchange does for calendar items.
    var bodylessUIDs: Set<UInt32> { get { sync { _bodyless } } set { sync { _bodyless = newValue } } }
    /// UIDs deleted from the mailbox the moment a body fetch arrives, as if
    /// another client expunged them between listing and download.
    var expungeOnBodyFetch: Set<UInt32> { get { sync { _expunge } } set { sync { _expunge = newValue } } }
    /// How many body fetches leave each UID out before it is returned (transient
    /// partial replies, as seen on Microsoft 365).
    var refusals: [UInt32: Int] { get { sync { _refusals } } set { sync { _refusals = newValue } } }
    /// When a body fetch leaves anything out: the tagged completion to send
    /// instead of OK (for example "NO [UNAVAILABLE] Try later"), and an untagged line to add.
    var partialCompletion: String? { get { sync { _partialCompletion } } set { sync { _partialCompletion = newValue } } }
    var partialUntagged: String? { get { sync { _partialUntagged } } set { sync { _partialUntagged = newValue } } }
    /// Refuse every AUTHENTICATE at once with this text (no SASL challenge),
    /// as Exchange does for an account without a mailbox.
    var authFailureText: String? { get { sync { _authFailure } } set { sync { _authFailure = newValue } } }
    /// Answer EXAMINE with READ-WRITE, to test that the session refuses it.
    var examineAnswersReadWrite: Bool { get { sync { _readWrite } } set { sync { _readWrite = newValue } } }

    // Observations.
    var commandLog: [String] { sync { _log } }
    var connectionCount: Int { sync { _connections } }
    var bodyFetchCount: Int { sync { _bodyFetches } }
    /// How many times each UID's body was sent.
    var bodiesServed: [UInt32: Int] { sync { _served } }

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
    private var _partialCompletion: String?
    private var _partialUntagged: String?
    private var _bodyless: Set<UInt32> = []
    private var _expunge: Set<UInt32> = []
    private var _log: [String] = []
    private var _connections = 0
    private var _bodyFetches = 0
    private var _served: [UInt32: Int] = [:]
    private(set) var port: UInt16 = 0

    private func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    init(mailboxes: [Mailbox] = []) {
        _mailboxes = mailboxes
    }

    func start() async throws -> UInt16 {
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

    func stop() {
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
            let name = Self.unquote(rest)
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
        let attributes = String(rest[rest.index(after: space)...]).uppercased()
        let wantsBody = attributes.contains("BODY.PEEK[]")
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
            if wantsBody, _bodyless.contains(message.uid) { omitted = true; continue }
            if wantsBody, let left = _refusals[message.uid], left > 0 {
                _refusals[message.uid] = left - 1
                omitted = true
                continue
            }
            var items = ["UID \(message.uid)", "RFC822.SIZE \(message.bytes.count)"]
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
            out.append(Data("* \(index + 1) FETCH (\(items.joined(separator: " "))".utf8))
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
        send(out, to: client)
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

    static func quote(_ text: String) -> String {
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
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
