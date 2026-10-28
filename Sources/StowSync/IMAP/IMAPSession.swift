import Foundation
import Logging
import NIOCore
import NIOIMAP
import NIOIMAPCore
import StowCore
import StowSecrets

/// A read-only conversation with one IMAP server (D-109).
///
/// The public functions are the whole API: there is nothing here that can
/// change a mailbox. Folders are opened with EXAMINE, never SELECT, and
/// messages are downloaded with BODY.PEEK[], never BODY[], so even the \Seen
/// flag stays as it was.
///
/// One command runs at a time. An actor guarantees that: callers queue up.
public actor IMAPSession {
    private let connection: IMAPConnection
    private let responses: ResponseInbox
    private var nextTag = 1
    private var knownCapabilities: Set<String>?
    private var lastBye: String?
    private var loggedOut = false
    /// iCloud answers EXAMINE with `[READ-WRITE]` (measured 28 Oct 2026, D-474).
    /// Only `SessionFactory` turns this on, only for iCloud accounts.
    private var acceptsReadWriteExamineLabel = false
    /// Held only while `AUTHENTICATE PLAIN` without SASL-IR waits for the server's `+`.
    private var plainCredentials: (user: String, password: AppSpecificPassword)?
    private let logger = Logger(label: "ee.getstow.sync.imap")
    private let timeouts: IMAPTimeouts
    /// The tag of a command whose deadline passed; its connection is closed.
    private var expiredTag: String?
    private var runningTag: String?
    /// FETCH responses for UIDs that were not asked for, over the session (A-13).
    private(set) var droppedResponses = 0

    /// Bytes per second a message fetch is allowed on top of `IMAPTimeouts.command`
    /// before its deadline, about 0.4 Mbit/s (D-496).
    static let messageFetchRate = 50_000
    /// Most bytes one message fetch may bring in: twice what was asked for
    /// plus a margin, as Exchange's sizes are estimates (D-120), never past
    /// the ceiling (D-496).
    static func messageByteLimit(expected: Int) -> Int {
        min(maximumReplyBytes, expected.multipliedReportingOverflow(by: 2).partialValue + (16 << 20))
    }
    static let maximumReplyBytes = 1 << 30
    /// Literal bytes allowed in a reply to any command that fetches no message bodies.
    static let nonBodyReplyBytes = 64 << 20
    /// Assumed size of a message when the caller gives none, for the limits above.
    static let assumedMessageBytes = 32 << 20

    private init(connection: IMAPConnection, timeouts: IMAPTimeouts) {
        self.connection = connection
        self.responses = ResponseInbox(connection.responses)
        self.timeouts = timeouts
    }

    /// Connects and reads the server's greeting.
    public static func connect(to endpoint: IMAPEndpoint, timeouts: IMAPTimeouts = .default) async throws -> IMAPSession {
        let connection = try await IMAPConnection.connect(to: endpoint, timeouts: timeouts)
        let session = IMAPSession(connection: connection, timeouts: timeouts)
        do {
            try await session.readGreeting()
        } catch {
            await connection.close()
            throw error
        }
        return session
    }

    // MARK: Public, read-only API

    /// Signs in with SASL XOAUTH2. Throws `SyncError.authenticationFailed` if refused.
    public func authenticate(user: String, accessToken: String) async throws {
        do {
            let text = try await run(.authenticateXOAUTH2(user: user, accessToken: accessToken)) { _ in }
            if case .capability(let list)? = text.code {
                knownCapabilities = Set(list.map { $0.name.uppercased() })
            } else {
                knownCapabilities = nil // They change after sign-in; ask again when needed.
            }
        } catch SyncError.commandFailed(_, let status, let text) {
            throw Self.classifyAuthenticationFailure("\(status) \(text)")
        }
    }

    /// Signs in with SASL PLAIN and an iCloud app-specific password (D-467),
    /// only over implicit TLS (the connection checks). Sends the credentials
    /// as an initial response when the server offers SASL-IR, otherwise in
    /// answer to its `+`. Throws `SyncError.authenticationFailed` if refused.
    public func authenticate(user: String, password: AppSpecificPassword) async throws {
        // Checked here before anything is sent, and again by the connection before it writes.
        guard connection.endpoint.allowsPassword else { throw SyncError.insecureConnection }
        let initialResponse = try await capabilities().contains("SASL-IR")
        plainCredentials = initialResponse ? nil : (user, password)
        defer { plainCredentials = nil }
        do {
            let text = try await run(.authenticatePlain(user: user, password: password, initialResponse: initialResponse)) { _ in }
            if case .capability(let list)? = text.code {
                knownCapabilities = Set(list.map { $0.name.uppercased() })
            } else {
                knownCapabilities = nil
            }
        } catch SyncError.commandFailed(_, let status, let text) {
            throw Self.classifyAuthenticationFailure("\(status) \(text)")
        }
    }

    /// Exchange says "User is authenticated but not connected." when the token
    /// is fine but there is no mailbox it can open (D-116).
    static func classifyAuthenticationFailure(_ text: String) -> SyncError {
        text.lowercased().contains("authenticated but not connected") ? .mailboxUnavailable(text) : .authenticationFailed(text)
    }

    /// Capability names, uppercased, for example `IMAP4REV1`, `X-GM-EXT-1`.
    public func capabilities() async throws -> Set<String> {
        if let knownCapabilities { return knownCapabilities }
        var found: Set<String> = []
        _ = try await run(.capability) { response in
            if case .untagged(.capabilityData(let list)) = response {
                found.formUnion(list.map { $0.name.uppercased() })
            }
        }
        knownCapabilities = found
        return found
    }

    /// The STORAGE quota that applies to a mailbox (INBOX by default), from
    /// GETQUOTAROOT, which only reads (R6, D-404). Nil when the server refuses
    /// the command or reports no storage limit. Callers send it only when the
    /// server advertises QUOTA after sign-in.
    public func storageQuota(of mailbox: [UInt8] = Array("INBOX".utf8)) async throws -> MailboxQuota? {
        var found: MailboxQuota?
        let completion = try await runForCompletion(.getQuotaRoot(rawName: mailbox)) { response in
            guard found == nil, case .untagged(.quota(_, let resources)) = response,
                  let storage = resources.first(where: { $0.resourceName.uppercased() == "STORAGE" })
            else { return }
            // Two numbers, nothing personal: what the server said, before Stow decides whether it means anything (D-404).
            logger.debug("GETQUOTAROOT storage", metadata: ["usageKiB": "\(storage.usage)", "limitKiB": "\(storage.limit)"])
            found = MailboxQuota.fromStorage(usageKiB: storage.usage, limitKiB: storage.limit)
        }
        guard completion.status == "OK" else {
            logger.debug("GETQUOTAROOT refused", metadata: ["status": "\(completion.status)", "text": "\(Self.describe(completion.text))"])
            return nil
        }
        return found
    }

    /// Every mailbox the server lists, including ones that cannot be opened.
    public func listFolders() async throws -> [IMAPFolder] {
        var folders: [IMAPFolder] = []
        _ = try await run(.listAll) { response in
            if case .untagged(.mailboxData(.list(let info))) = response {
                folders.append(Self.folder(from: info))
            }
        }
        return folders
    }

    /// iCloud's EXAMINE says `[READ-WRITE]` although nothing Stow sends can
    /// write (D-474). Called by `SessionFactory` for iCloud accounts only; there
    /// is no way to turn it off again for the session.
    func acceptReadWriteExamineLabel() {
        acceptsReadWriteExamineLabel = true
    }

    /// Opens a folder read-only. Refuses to continue unless the server confirms
    /// READ-ONLY (an iCloud session also accepts its `[READ-WRITE]` label to
    /// EXAMINE, D-474). With `condstore`, also asks for HIGHESTMODSEQ (D-038).
    public func examine(_ folder: IMAPFolder, condstore: Bool = false) async throws -> FolderStatus {
        var uidValidity: UInt32?
        var uidNext: UInt32?
        var highestModSeq: UInt64?
        var exists = 0
        let text = try await run(.examine(rawName: folder.rawName, condstore: condstore)) { response in
            switch response {
            case .untagged(.mailboxData(.exists(let count))):
                exists = count
            case .untagged(.conditionalState(.ok(let text))):
                switch text.code {
                case .uidValidity(let value)?: uidValidity = UInt32(value)
                case .uidNext(let uid)?: uidNext = uid.rawValue
                case .highestModificationSequence(let value)?: highestModSeq = UInt64(value)
                default: break
                }
            default:
                break
            }
        }
        switch text.code {
        case .readOnly?:
            break
        case .readWrite? where acceptsReadWriteExamineLabel:
            // Still EXAMINE, never SELECT; nothing Stow can send writes (D-109, D-474).
            logger.debug("EXAMINE answered READ-WRITE; accepted for iCloud (D-474)")
        default:
            // EXAMINE must always answer [READ-ONLY]. Anything else and we stop.
            throw SyncError.protocolViolation("EXAMINE was not confirmed as read-only")
        }
        guard let uidValidity else {
            throw SyncError.protocolViolation("EXAMINE gave no UIDVALIDITY")
        }
        return FolderStatus(uidValidity: uidValidity, uidNext: uidNext, exists: exists, highestModSeq: highestModSeq)
    }

    /// UIDs, sizes, arrival dates and (for Gmail) message IDs of the messages
    /// whose UID is in `range`, in UID order. Downloads no message content.
    public func fetchUIDs(_ range: ClosedRange<UInt32>, gmail: Bool = false) async throws -> [MessageSummary] {
        var builder = FetchAssembler(wanted: .range(range))
        _ = try await run(.fetchSummaries(range, gmail: gmail)) { try builder.consume($0) }
        noteDropped(builder)
        return builder.finished
            .compactMap { message in
                message.uid.map {
                    MessageSummary(uid: $0, size: message.size ?? 0, internalDate: message.internalDate, gmailMessageID: message.gmailMessageID)
                }
            }
            .filter { range.contains($0.uid) } // "n:hi" can return the last message even if below n.
            .sorted { $0.uid < $1.uid }
    }

    /// UIDs and sizes of whichever of `uids` still exist. Downloads no content.
    public func fetchUIDs(_ uids: [UInt32]) async throws -> [MessageSummary] {
        guard !uids.isEmpty else { return [] }
        var builder = FetchAssembler(wanted: .uids(Set(uids)))
        _ = try await run(.fetchSummariesOf(uids: uids)) { try builder.consume($0) }
        noteDropped(builder)
        let wanted = Set(uids)
        return builder.finished
            .compactMap { message in
                message.uid.map { MessageSummary(uid: $0, size: message.size ?? 0, internalDate: message.internalDate, flags: message.flags) }
            }
            .filter { wanted.contains($0.uid) }
            .sorted { $0.uid < $1.uid }
    }

    /// The named header fields of each message, by UID (`BODY.PEEK[HEADER.FIELDS (...)]`).
    /// Read only, and only those fields.
    public func fetchHeaderFields(uids: [UInt32], fields: [String]) async throws -> [UInt32: Data] {
        guard !uids.isEmpty else { return [:] }
        return try await headerFields(.list(uids), wanted: .uids(Set(uids)), fields: fields)
    }

    /// Like `fetchHeaderFields(uids:fields:)`, for every message in a UID range.
    public func fetchHeaderFields(_ range: ClosedRange<UInt32>, fields: [String]) async throws -> [UInt32: Data] {
        try await headerFields(.range(range), wanted: .range(range), fields: fields)
    }

    private func headerFields(_ selection: UIDSelection, wanted: FetchAssembler.Wanted, fields: [String]) async throws -> [UInt32: Data] {
        var builder = FetchAssembler(wanted: wanted)
        _ = try await run(.fetchHeaderFields(selection, fields: fields)) { try builder.consume($0) }
        noteDropped(builder)
        var result: [UInt32: Data] = [:]
        for message in builder.finished {
            if let uid = message.uid { result[uid] = message.headerFields ?? Data() }
        }
        return result
    }

    /// Flags (and Gmail labels) of the messages in `range`: all of them, or with
    /// `changedSince` only those whose CONDSTORE mod-sequence is higher (D-038).
    public func fetchStates(_ range: ClosedRange<UInt32>, gmail: Bool, changedSince: UInt64? = nil) async throws -> [CopyState] {
        var builder = FetchAssembler(wanted: .range(range))
        _ = try await run(.fetchStates(range, gmail: gmail, changedSince: changedSince)) { try builder.consume($0) }
        noteDropped(builder)
        return builder.finished
            .compactMap { message in
                message.uid.map { CopyState(uid: $0, flags: message.flags, labels: gmail ? message.labels : nil) }
            }
            .filter { range.contains($0.uid) }
            .sorted { $0.uid < $1.uid }
    }

    /// The Gmail message IDs in the open folder's `range` (D-039). Identifiers only.
    public func fetchGmailIDs(_ range: ClosedRange<UInt32>) async throws -> Set<UInt64> {
        var builder = FetchAssembler(wanted: .range(range))
        _ = try await run(.fetchGmailIDs(range)) { try builder.consume($0) }
        noteDropped(builder)
        return Set(builder.finished.compactMap(\.gmailMessageID))
    }

    /// Downloads complete messages with BODY.PEEK[]. Messages deleted on the
    /// server in the meantime are simply absent from the result.
    public func fetchMessages(uids: [UInt32], gmail: Bool, expectedBytes: Int? = nil) async throws -> [FetchedMessage] {
        try await fetchMessagesWithDiagnostics(uids: uids, gmail: gmail, expectedBytes: expectedBytes).messages
    }

    /// Like `fetchMessages`, plus how the server completed the command, for
    /// diagnosing partial replies (D-118). A NO completion is treated as a
    /// partial reply rather than an error: whatever arrived is returned. Only a
    /// quota reply still throws.
    ///
    /// `expectedBytes`, the sizes the server listed for these messages, sets
    /// how many bytes the reply may bring and how long it may take (D-496).
    public func fetchMessagesWithDiagnostics(
        uids: [UInt32], gmail: Bool, expectedBytes: Int? = nil
    ) async throws -> (messages: [FetchedMessage], diagnostics: FetchDiagnostics) {
        guard !uids.isEmpty else { return ([], FetchDiagnostics(status: "OK")) }
        let expected = min(expectedBytes ?? uids.count.multipliedReportingOverflow(by: Self.assumedMessageBytes).partialValue,
                           Self.maximumReplyBytes)
        var builder = FetchAssembler(wanted: .uids(Set(uids)), byteLimit: Self.messageByteLimit(expected: expected))
        var untagged: [String] = []
        let byeBefore = lastBye
        let deadline = timeouts.command + Double(expected / Self.messageFetchRate)
        let completion = try await runForCompletion(.fetchMessages(uids: uids, gmail: gmail), deadline: deadline) { response in
            switch response {
            case .untagged(.conditionalState(.no(let text))): untagged.append("NO " + Self.describe(text))
            case .untagged(.conditionalState(.bad(let text))): untagged.append("BAD " + Self.describe(text))
            default: try builder.consume(response)
            }
        }
        noteDropped(builder)
        if lastBye != byeBefore, let bye = lastBye { untagged.append("BYE " + bye) }
        switch completion.status {
        case "OK":
            break
        case "NO":
            // Kept as a partial reply (with its diagnostics) unless it is a
            // daily quota reply, which no amount of retrying will fix. A
            // throttling NO is also kept: the in-run retry already backs off.
            let failure = Self.classifyFailure(command: "UID FETCH", status: "NO", text: completion.text)
            if case .quotaExceeded = failure { throw failure }
        default:
            throw Self.classifyFailure(command: "UID FETCH", status: completion.status, text: completion.text)
        }
        let diagnostics = FetchDiagnostics(
            status: completion.status,
            code: completion.text.code.map { Redact.scrub(String(describing: $0)) },
            text: Self.describe(completion.text),
            untagged: untagged
        )
        let wanted = Set(uids)
        let messages = try builder.finished.compactMap { partial -> FetchedMessage? in
            guard let uid = partial.uid, wanted.contains(uid) else { return nil }
            guard let bytes = partial.body else {
                throw SyncError.protocolViolation("FETCH reply for UID \(uid) had no message body")
            }
            if let announced = partial.announcedBodyLength, announced != bytes.count {
                throw SyncError.protocolViolation("FETCH body for UID \(uid) was \(bytes.count) bytes, announced \(announced)")
            }
            guard let internalDate = partial.internalDate else {
                throw SyncError.protocolViolation("FETCH reply for UID \(uid) had no INTERNALDATE")
            }
            return FetchedMessage(
                uid: uid,
                size: partial.size ?? bytes.count,
                internalDate: internalDate,
                gmailMessageID: partial.gmailMessageID,
                gmailThreadID: partial.gmailThreadID,
                labels: partial.labels,
                flags: partial.flags,
                bytes: bytes
            )
        }.sorted { $0.uid < $1.uid }
        return (messages, diagnostics)
    }

    private func noteDropped(_ builder: FetchAssembler) {
        guard builder.dropped > 0 else { return }
        droppedResponses += builder.dropped
        logger.notice("Dropped FETCH responses for UIDs that were not asked for", metadata: ["count": "\(builder.dropped)"])
    }

    /// Server free text for logs: scrubbed (D-014) and kept short.
    static func describe(_ text: ResponseText) -> String {
        String(Redact.scrub(text.text).prefix(200))
    }

    /// Says goodbye and closes the connection. Never throws.
    public func logout() async {
        guard !loggedOut else { return }
        loggedOut = true
        _ = try? await run(.logout) { _ in }
        await connection.close()
    }

    /// Closes the connection without LOGOUT, for cancellation and errors.
    public func disconnect() async {
        loggedOut = true
        await connection.close()
    }

    // MARK: Conversation

    private func readGreeting() async throws {
        guard let response = try await nextResponse() else {
            throw SyncError.connectionClosed(lastBye)
        }
        switch response {
        case .untagged(.conditionalState(.ok(let text))), .untagged(.conditionalState(.preauth(let text))):
            if case .capability(let list)? = text.code {
                knownCapabilities = Set(list.map { $0.name.uppercased() })
            }
        case .untagged(.conditionalState(.bye(let text))), .fatal(let text):
            throw Self.classifyBye(Redact.scrub(text.text))
        default:
            throw SyncError.protocolViolation("Unexpected greeting")
        }
    }

    private func nextResponse() async throws -> Response? {
        do {
            let response = try await responses.next()
            if response == nil, Task.isCancelled { throw SyncError.cancelled }
            return response
        } catch let error as SyncError {
            throw error
        } catch is CancellationError {
            throw SyncError.cancelled
        } catch {
            throw SyncError.connectionClosed(Redact.scrub(String(describing: error)))
        }
    }

    /// Sends one command and feeds every reply to `handle` until the tagged
    /// completion. Returns the text of the OK; throws on NO, BAD or BYE.
    private func run(_ command: ReadOnlyCommand, handle: (Response) throws -> Void) async throws -> ResponseText {
        let completion = try await runForCompletion(command, handle: handle)
        switch completion.status {
        case "OK": return completion.text
        default: throw Self.classifyFailure(command: command.verb, status: completion.status, text: completion.text)
        }
    }

    /// Sends one command and feeds every reply to `handle` until the tagged
    /// completion, which it returns whether OK, NO or BAD. Throws on BYE or a lost connection.
    ///
    /// The command must finish within `deadline` (default `IMAPTimeouts.command`),
    /// separately from the idle timer, which a reply trickling in never trips.
    /// At the deadline the connection is closed and the command fails with a
    /// retryable error (A-13, D-496). If `handle` throws, the rest of the reply
    /// is still on its way, so the connection is closed too.
    private func runForCompletion(
        _ command: ReadOnlyCommand, deadline: TimeInterval? = nil, handle: (Response) throws -> Void
    ) async throws -> (status: String, text: ResponseText) {
        if Task.isCancelled {
            await disconnect()
            throw SyncError.cancelled
        }
        let tag = "S\(nextTag)"
        nextTag += 1
        let limit = deadline ?? timeouts.command
        let verb = command.verb
        let watchdog = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            await self?.deadlinePassed(tag: tag, command: verb, seconds: limit)
        }
        defer { watchdog.cancel() }
        do {
            return try await exchange(command, tag: tag, handle: handle)
        } catch {
            if expiredTag == tag {
                throw SyncError.connectionClosed("\(verb) took longer than \(Int(limit)) s, so Stow closed the connection")
            }
            throw error
        }
    }

    private func deadlinePassed(tag: String, command: String, seconds: TimeInterval) async {
        guard runningTag == tag else { return }
        expiredTag = tag
        logger.warning("IMAP command passed its deadline; closing the connection",
                       metadata: ["command": "\(command)", "seconds": "\(Int(seconds))"])
        await connection.close()
    }

    private func exchange(_ command: ReadOnlyCommand, tag: String, handle: (Response) throws -> Void) async throws -> (status: String, text: ResponseText) {
        runningTag = tag
        defer { runningTag = nil }
        logger.debug("IMAP command", metadata: ["tag": "\(tag)", "command": "\(command.verb)"])
        try await connection.send(tag: tag, command)
        while true {
            guard let response = try await nextResponse() else {
                if case .logout = command { return ("OK", ResponseText(text: "")) }
                throw Self.classifyBye(lastBye)
            }
            switch response {
            case .tagged(let tagged) where tagged.tag == tag:
                switch tagged.state {
                case .ok(let text): return ("OK", text)
                case .no(let text): return ("NO", text)
                case .bad(let text): return ("BAD", text)
                }
            case .authenticationChallenge:
                if let credentials = plainCredentials {
                    // PLAIN without SASL-IR: the first `+` asks for the credentials (once).
                    plainCredentials = nil
                    try await connection.sendPlainResponse(user: credentials.user, password: credentials.password)
                } else {
                    // XOAUTH2 reports failure as a challenge carrying JSON; the
                    // client must answer with an empty line to get the final NO.
                    // A second challenge to PLAIN is answered the same way.
                    try await connection.sendEmptyContinuation()
                }
            case .untagged(.conditionalState(.bye(let text))), .fatal(let text):
                lastBye = Redact.scrub(text.text)
                if case .logout = command { continue }
                logger.notice("Server sent BYE", metadata: ["text": "\(lastBye ?? "")"])
            default:
                do {
                    try handle(response)
                } catch {
                    await disconnect()
                    throw error
                }
            }
        }
    }

    static func classifyFailure(command: String, status: String, text: ResponseText) -> SyncError {
        let scrubbed = Redact.scrub(text.text)
        let lower = scrubbed.lowercased()
        switch text.code {
        case .overQuota?, .limit?:
            return .quotaExceeded(scrubbed)
        case .unavailable?, .inUse?:
            return .throttled(scrubbed)
        case .other(let name, _)? where name.uppercased() == "OVERQUOTA":
            return .quotaExceeded(scrubbed)
        case .other(let name, _)? where name.uppercased() == "THROTTLED":
            return .throttled(scrubbed)
        default:
            break
        }
        if lower.contains("bandwidth") || lower.contains("overquota") { return .quotaExceeded(scrubbed) }
        if lower.contains("throttl") || lower.contains("try again later") || lower.contains("server busy") {
            return .throttled(scrubbed)
        }
        return .commandFailed(command: command, status: status, text: scrubbed)
    }

    static func classifyBye(_ text: String?) -> SyncError {
        guard let text else { return .connectionClosed(nil) }
        let lower = text.lowercased()
        if lower.contains("bandwidth") || lower.contains("overquota") { return .quotaExceeded(text) }
        if lower.contains("throttl") || lower.contains("too many") { return .throttled(text) }
        return .connectionClosed(text)
    }

    static func folder(from info: MailboxInfo) -> IMAPFolder {
        let path = info.path
        let separator = path.pathSeparator
        let name = path.displayStringComponents(omittingEmptySubsequences: false)
            .joined(separator: separator.map(String.init) ?? "")
        return IMAPFolder(
            name: name,
            rawName: path.name.bytes,
            separator: separator,
            attributes: Set(info.attributes.map { String($0) })
        )
    }
}

/// Holds the reply stream's iterator. Only the owning `IMAPSession` actor
/// calls `next()`, one call at a time, which is what makes the unchecked
/// `Sendable` safe. (`next(isolation:)` would avoid this but needs macOS 15.)
private final class ResponseInbox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Response, Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<Response, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Response? {
        try await iterator.next()
    }
}
