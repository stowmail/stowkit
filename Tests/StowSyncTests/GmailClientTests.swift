import Foundation
import StowCore
import Testing
@testable import StowSync

/// Plays Google's Gmail API: records every request it is handed and answers
/// from a closure. It is only ever handed `GmailGet` values.
actor FakeGmailTransport: GmailTransport {
    struct Seen: Sendable {
        var url: URL
        var accessToken: String
    }

    private(set) var seen: [Seen] = []
    private let answer: @Sendable (GmailGet, Int) -> GmailHTTPResponse

    init(answer: @escaping @Sendable (GmailGet, Int) -> GmailHTTPResponse) {
        self.answer = answer
    }

    /// Answers every request with the same status and JSON body.
    init(status: Int = 200, json: String, retryAfter: TimeInterval? = nil) {
        self.init { _, _ in GmailHTTPResponse(status: status, body: Data(json.utf8), retryAfter: retryAfter) }
    }

    func send(_ request: GmailGet, accessToken: String) async throws -> GmailHTTPResponse {
        seen.append(Seen(url: request.url, accessToken: accessToken))
        return answer(request, seen.count)
    }
}

/// Counts token requests and which asked for a refresh.
actor TokenCounter {
    private(set) var calls: [Bool] = []
    let tokens: [String]
    init(_ tokens: [String]) { self.tokens = tokens }
    func next(force: Bool) -> String {
        calls.append(force)
        return tokens[min(calls.count - 1, tokens.count - 1)]
    }
}

let gmailSentinelToken = "ya29.SENTINEL-gmail-token-7Qk2"
let gmailTestAccount = AccountID(rawValue: "acct-gmail-test")

/// Counts how often the client asked for the account to be marked as needing sign-in.
actor MarkCounter {
    private(set) var count = 0
    func mark() { count += 1 }
}

func gmailClient(_ transport: FakeGmailTransport, tokens: TokenCounter = TokenCounter([gmailSentinelToken]),
                 marks: MarkCounter = MarkCounter()) -> GmailClient {
    GmailClient(account: gmailTestAccount, transport: transport, markNeedsSignIn: { await marks.mark() }) { force in
        await tokens.next(force: force)
    }
}

/// Every request Stow can express, with awkward values.
let everyGmailRequest: [GmailReadOnlyRequest] = [
    .profile,
    .labels,
    .messages(GmailMessageListQuery()),
    .messages(GmailMessageListQuery(q: "from:a+b@example.com & x=y/z", labelIDs: [.spam, GmailLabelID("Label_7")!],
                                    includeSpamTrash: true, pageToken: "tok/en+=", maxResults: 9999)),
    .message(GmailMessageID("17c9a3b2f0e1d4c5")!, format: .raw),
    .message(GmailMessageID("1")!, format: .minimal),
    .message(GmailMessageID("abc")!, format: .metadata(headers: ["Message-ID", "Date"])),
    .history(GmailHistoryQuery(startHistoryID: 123_456)),
    .history(GmailHistoryQuery(startHistoryID: 1, historyTypes: [.messageAdded], labelID: .trash, pageToken: "p&q", maxResults: 0)),
]

/// The second read-only guarantee for Gmail (D-583, D-109): what Stow can say to the API.
@Suite struct GmailReadOnlyRequestTests {
    @Test func everyRequestIsAGetOnGmailUnderUsersMe() {
        #expect(GmailGet.method == "GET")
        for request in everyGmailRequest {
            let url = request.get.url
            #expect(url.scheme == "https")
            #expect(url.host == "gmail.googleapis.com")
            #expect(url.port == nil)
            #expect(url.user == nil && url.password == nil)
            #expect(url.path.hasPrefix("/gmail/v1/users/me/"), "\(url.path)")
            let rest = String(url.path.dropFirst("/gmail/v1/users/me/".count))
            let allowed = ["profile", "labels", "messages", "history"]
            #expect(allowed.contains(rest) || (rest.hasPrefix("messages/") && GmailMessageID(String(rest.dropFirst(9))) != nil), "\(rest)")
            #expect(url.fragment == nil)
        }
    }

    @Test func namesAndPathsMatchGooglesReference() {
        #expect(GmailReadOnlyRequest.profile.get.url.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/profile")
        #expect(GmailReadOnlyRequest.labels.get.url.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/labels")
        #expect(GmailReadOnlyRequest.messages(GmailMessageListQuery()).get.url.absoluteString
            == "https://gmail.googleapis.com/gmail/v1/users/me/messages?includeSpamTrash=false&maxResults=500")
        #expect(GmailReadOnlyRequest.message(GmailMessageID("17c9a3b2f0e1d4c5")!, format: .raw).get.url.absoluteString
            == "https://gmail.googleapis.com/gmail/v1/users/me/messages/17c9a3b2f0e1d4c5?format=raw")
        #expect(GmailReadOnlyRequest.message(GmailMessageID("abc")!, format: .metadata(headers: ["Message-ID", "Date"])).get.url.query
            == "format=metadata&metadataHeaders=Message-ID&metadataHeaders=Date")
        #expect(GmailReadOnlyRequest.history(GmailHistoryQuery(startHistoryID: 42, historyTypes: [.messageAdded, .labelRemoved])).get.url.query
            == "startHistoryId=42&historyTypes=messageAdded&historyTypes=labelRemoved&maxResults=500")
        #expect(everyGmailRequest.map(\.name).allSatisfy { ["users.getProfile", "users.labels.list", "users.messages.list", "users.messages.get", "users.history.list"].contains($0) })
    }

    /// A search term or page token can never add a parameter or a path.
    @Test func queryValuesAreFullyEncoded() throws {
        let url = everyGmailRequest[3].get.url
        let query = try #require(url.query)
        #expect(query == "q=from%3Aa%2Bb%40example.com%20%26%20x%3Dy%2Fz&labelIds=SPAM&labelIds=Label_7&includeSpamTrash=true&pageToken=tok%2Fen%2B%3D&maxResults=500")
        // maxResults is held to Google's 1 to 500.
        #expect(everyGmailRequest[8].get.url.query?.hasSuffix("maxResults=1") == true)
        // The description names the call only.
        #expect(everyGmailRequest[3].get.description == "GmailGet(users.messages.list)")
    }

    @Test func idsCannotCarryAPath() {
        for bad in ["", "../drafts", "17C9", "17c9/send", "17c9?x", "0123456789abcdef0", "g", " 1", "1%2F"] {
            #expect(GmailMessageID(bad) == nil, "\(bad)")
        }
        for bad in ["", "Label 1", "a/b", "INBOX?x", "é", String(repeating: "a", count: 129)] {
            #expect(GmailLabelID(bad) == nil, "\(bad)")
        }
        #expect(GmailLabelID("CATEGORY_SOCIAL") != nil && GmailLabelID("Label_12-3") != nil)
    }

    /// Google's IMAP extensions page: X-GM-MSGID is the decimal form of the API's hex ID.
    @Test func hexIDsAreTheIMAPNumbers() throws {
        let id = GmailMessageID(number: 1_278_455_344_230_334_865)
        #expect(id.rawValue == "11bdfc5cae0c8191")
        #expect(try #require(GmailMessageID("11bdfc5cae0c8191")).number == 1_278_455_344_230_334_865)
        #expect(GmailMessageID(number: UInt64.max).rawValue == "ffffffffffffffff")
    }
}

@Suite struct GmailClientTests {
    @Test func sendsTheTokenToTheTransportOnly() async throws {
        let transport = FakeGmailTransport(json: #"{"emailAddress":"sam@example.com","messagesTotal":3,"threadsTotal":2,"historyId":"9001"}"#)
        let profile = try await gmailClient(transport).profile()
        #expect(profile.historyID == 9001)
        #expect(profile.messagesTotal == 3)
        #expect(!String(describing: profile).contains("sam@example.com"))
        let seen = await transport.seen
        #expect(seen.count == 1)
        #expect(seen[0].accessToken == gmailSentinelToken)
        #expect(!seen[0].url.absoluteString.contains("SENTINEL"))
    }

    /// One 401 is tried again with a refreshed token; a second gives up (no loop, D-110).
    @Test func a401RefreshesOnceAndOnlyOnce() async throws {
        let ok = FakeGmailTransport { _, n in
            GmailHTTPResponse(status: n == 1 ? 401 : 200, body: Data(#"{"labels":[]}"#.utf8))
        }
        let tokens = TokenCounter(["old", "new"])
        #expect(try await gmailClient(ok, tokens: tokens).labels().isEmpty)
        #expect(await tokens.calls == [false, true])
        #expect(await ok.seen.map(\.accessToken) == ["old", "new"])

        let never = FakeGmailTransport(status: 401, json: #"{"error":{"code":401,"message":"Invalid Credentials \#(gmailSentinelToken)","errors":[{"reason":"authError"}]}}"#)
        let again = TokenCounter(["old", "new"])
        do {
            _ = try await gmailClient(never, tokens: again).labels()
            Issue.record("expected an error")
        } catch let error as SyncError {
            guard case .authenticationFailed(let text) = error else { Issue.record("\(error)"); return }
            #expect(text.contains("authError"))
            #expect(!error.description.contains("SENTINEL") && !error.description.contains("Invalid Credentials"))
        }
        #expect(await again.calls == [false, true])
        #expect(await never.seen.count == 2)
    }

    @Test func limitsAndFaultsBecomeTheirOwnErrors() async throws {
        func error(_ status: Int, _ reason: String?, retryAfter: TimeInterval? = nil) async -> Error? {
            let body = reason.map { #"{"error":{"code":\#(status),"message":"Free text with sam@example.com","errors":[{"domain":"usageLimits","reason":"\#($0)"}]}}"# } ?? "{}"
            let transport = FakeGmailTransport(status: status, json: body, retryAfter: retryAfter)
            do { _ = try await gmailClient(transport).profile(); return nil } catch { return error }
        }
        let tooMany = await error(429, nil, retryAfter: 30)
        #expect(tooMany as? SyncError == .throttled("Gmail (HTTP 429, retry after 30 s)"))
        #expect(await error(403, "rateLimitExceeded") as? SyncError == .throttled("Gmail (HTTP 403, rateLimitExceeded)"))
        #expect(await error(403, "userRateLimitExceeded") as? SyncError == .throttled("Gmail (HTTP 403, userRateLimitExceeded)"))
        #expect(await error(403, "dailyLimitExceeded") as? SyncError == .quotaExceeded("Gmail (HTTP 403, dailyLimitExceeded)"))
        #expect(await error(404, "notFound") as? GmailNotFound == GmailNotFound(call: "users.getProfile"))
        let backend = await error(503, "backendError") as? SyncError
        #expect(backend == .providerUnavailable("Gmail (HTTP 503, backendError)"))
        #expect(backend?.isRetryable == true)
        let other = await error(400, "badRequest") as? SyncError
        #expect(other == .commandFailed(command: "users.getProfile", status: "HTTP 400", text: "badRequest"))
        #expect(other?.isRetryable == false)
        for case let failure? in [tooMany, other, backend] {
            #expect(!String(describing: failure).contains("sam@example.com"))
            #expect(!String(describing: failure).contains("Free text"))
        }
    }

    /// Step 7 (D-592): each refusal its own message; only a missing permission
    /// marks the account, and only once per refusal, never in a loop.
    @Test func refusalsHaveTheirOwnMessages() async throws {
        func refuse(_ status: Int, _ json: String) async -> (Error?, Int, Int) {
            let transport = FakeGmailTransport(status: status, json: json)
            let marks = MarkCounter()
            var caught: Error?
            do { _ = try await gmailClient(transport, marks: marks).labels() } catch { caught = error }
            return (caught, await marks.count, await transport.seen.count)
        }
        let scope = await refuse(403, #"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED"}}"#)
        #expect(scope.0 as? SyncError == .permissionMissing(gmailTestAccount))
        #expect(scope.1 == 1 && scope.2 == 1)
        let scope2 = await refuse(403, #"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#)
        #expect(scope2.0 as? SyncError == .permissionMissing(gmailTestAccount))

        let admin = await refuse(403, #"{"error":{"code":403,"errors":[{"reason":"domainPolicy"}]}}"#)
        #expect(admin.0 as? SyncError == .blockedByAdmin)
        #expect(admin.1 == 0)
        let disabled = await refuse(403, #"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#)
        #expect(disabled.0 as? SyncError == .gmailAPIUnavailable)
        #expect(disabled.1 == 0)
        let disabled2 = await refuse(403, #"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#)
        #expect(disabled2.0 as? SyncError == .gmailAPIUnavailable)

        for error: SyncError in [.permissionMissing(gmailTestAccount), .blockedByAdmin, .gmailAPIUnavailable] {
            #expect(!error.isRetryable)
        }
        #expect(SyncError.permissionMissing(gmailTestAccount).description.contains("stowmail account signin acct-gmail-test"))
        #expect(SyncError.blockedByAdmin.description.contains("Ask your admin"))
        #expect(SyncError.gmailAPIUnavailable.description.contains("our fault, not yours"))
        #expect(SyncError.throttled("Gmail (HTTP 429)").isRetryable)
    }

    @Test func rawMessagesAreDecodedByteForByte() async throws {
        // Bytes whose base64 holds both `+` and `/`, so base64url holds `-` and `_`.
        let bytes = Data([0xFB, 0xFF, 0xBF, 0x0D, 0x0A, 0x00, 0x7E, 0xFE])
        let raw = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(raw.contains("-") || raw.contains("_"))
        let json = #"{"id":"17c9a3b2f0e1d4c5","threadId":"17c9a3b2f0e1d4c0","labelIds":["INBOX","UNREAD"],"historyId":"77","internalDate":"1700000000123","sizeEstimate":8,"raw":"\#(raw)"}"#
        let message = try await gmailClient(FakeGmailTransport(json: json)).message(GmailMessageID("17c9a3b2f0e1d4c5")!, format: .raw)
        #expect(message.raw == bytes)
        #expect(message.threadID.rawValue == "17c9a3b2f0e1d4c0")
        #expect(message.labelIDs.map(\.rawValue) == ["INBOX", "UNREAD"])
        #expect(message.internalDateMilliseconds == 1_700_000_000_123)
        #expect(message.historyID == 77)
        #expect(!String(describing: message).contains(raw))
    }

    /// An ID in a reply is checked like one Stow made, so a hostile reply cannot
    /// steer a later request; a reply about another message is refused.
    @Test func hostileRepliesAreRefused() async throws {
        let list = FakeGmailTransport(json: #"{"messages":[{"id":"../drafts","threadId":"1"}]}"#)
        await #expect(throws: SyncError.protocolViolation("Gmail sent a users.messages.list reply Stow could not read")) {
            _ = try await gmailClient(list).messages(GmailMessageListQuery())
        }
        let other = FakeGmailTransport(json: #"{"id":"2","threadId":"2","raw":"AA"}"#)
        await #expect(throws: SyncError.protocolViolation("Gmail answered users.messages.get with another message")) {
            _ = try await gmailClient(other).message(GmailMessageID("1")!, format: .raw)
        }
        let noRaw = FakeGmailTransport(json: #"{"id":"1","threadId":"1"}"#)
        await #expect(throws: SyncError.protocolViolation("Gmail sent no raw message")) {
            _ = try await gmailClient(noRaw).message(GmailMessageID("1")!, format: .raw)
        }
    }

    @Test func emptyPagesAndHistoryDecode() async throws {
        let empty = try await gmailClient(FakeGmailTransport(json: #"{"resultSizeEstimate":0}"#)).messages(GmailMessageListQuery())
        #expect(empty.messages.isEmpty && empty.nextPageToken == nil)
        let json = #"{"history":[{"id":"5","messagesAdded":[{"message":{"id":"a","threadId":"a","labelIds":["INBOX"]}}],"labelsRemoved":[{"message":{"id":"b","threadId":"a"},"labelIds":["UNREAD"]}]}],"historyId":"6"}"#
        let history = try await gmailClient(FakeGmailTransport(json: json)).history(GmailHistoryQuery(startHistoryID: 4))
        #expect(history.historyID == 6)
        #expect(history.history.first?.messagesAdded.first?.message.id.rawValue == "a")
        #expect(history.history.first?.labelsRemoved.first?.labelIDs == [GmailLabelID("UNREAD")!])
    }

    /// Security checklist: a sentinel token appears in no URL, log line, error or
    /// description, at any level, whatever Google answers.
    @Test func sentinelTokenAppearsNowhere() async throws {
        _ = CapturedLogs.installed
        var texts: [String] = []
        for status in [200, 401, 403, 404, 429, 500] {
            let body = #"{"error":{"code":\#(status),"message":"echo \#(gmailSentinelToken)","errors":[{"reason":"\#(gmailSentinelToken)"}]}}"#
            let transport = FakeGmailTransport(status: status, json: body, retryAfter: 1)
            for request in everyGmailRequest {
                texts.append(request.get.url.absoluteString)
                texts.append(String(describing: request.get))
                do { _ = try await gmailClient(transport).send(request) } catch {
                    texts.append(String(describing: error))
                    texts.append(String(reflecting: error))
                }
            }
        }
        let logs = CapturedLogs.shared.all
        #expect(logs.contains { $0.contains("ee.getstow.sync.gmail") })
        for text in texts + logs {
            #expect(!text.contains("SENTINEL"), "\(text)")
        }
    }

    @Test func networkFailuresNeverOfferToSkipTheCertificateCheck() {
        #expect(URLSessionGmailTransport.syncError(URLError(.serverCertificateUntrusted)) == .certificateRejected("URL error \(URLError.Code.serverCertificateUntrusted.rawValue)"))
        #expect(URLSessionGmailTransport.syncError(URLError(.secureConnectionFailed)).description.contains("never skips"))
        #expect(URLSessionGmailTransport.syncError(URLError(.notConnectedToInternet)) == .connectionFailed("this Mac is offline"))
        #expect(URLSessionGmailTransport.syncError(URLError(.dnsLookupFailed)).isRetryable)
        #expect(URLSessionGmailTransport.syncError(URLError(.timedOut)) == .timedOut)
    }
}

/// Belt and braces, as `sourceNamesNoWriteCommand` for IMAP: the Gmail sources
/// set no HTTP method but `GmailGet.method`, build no request outside the
/// transport, and name no Gmail write path (D-583).
@Suite struct GmailSourceScanTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    static func swiftFiles(in folder: URL) -> [URL] {
        (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
    }

    @Test func gmailSourcesNameNoWritePathOrOtherMethod() throws {
        let files = Self.swiftFiles(in: Self.sources.appendingPathComponent("StowSync/Gmail"))
        #expect(files.count >= 4)
        let writePaths = try Regex(#""[^"\n]*\b(modify|trash|untrash|delete|send|insert|import|batchModify|batchDelete|watch|stop|drafts|settings|filters|forwardingAddresses|sendAs|delegates|batch)\b[^"\n]*""#)
        let methods = try Regex(#"\b(POST|PUT|PATCH|DELETE)\b"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(code.firstMatch(of: writePaths) == nil, "\(file.lastPathComponent) names a Gmail write path")
            #expect(code.firstMatch(of: methods) == nil, "\(file.lastPathComponent) names an HTTP method other than GET")
            for line in code.split(separator: "\n") where line.contains("httpMethod") {
                #expect(line.contains("httpMethod = GmailGet.method"), "\(file.lastPathComponent): \(line)")
            }
            if file.lastPathComponent != "GmailTransport.swift" {
                #expect(!code.contains("URLRequest(") && !code.contains("URLSession(") && !code.contains("URLSession.shared"), "\(file.lastPathComponent) builds its own request")
            }
            #expect(!code.contains("httpBody") && !code.contains("upload(") && !code.contains("uploadTask"), "\(file.lastPathComponent)")
        }
        // `GmailGet`'s initialiser is private to the file that lists the requests.
        let request = try String(contentsOf: Self.sources.appendingPathComponent("StowSync/Gmail/GmailReadOnlyRequest.swift"), encoding: .utf8)
        #expect(request.contains("fileprivate init(url: URL, name: String)"))
    }

    /// Nothing outside StowSync/Gmail talks to the Gmail API, and no source asks
    /// Google for a wider scope.
    @Test func onlyTheGmailFolderReachesTheAPI() throws {
        for file in Self.swiftFiles(in: Self.sources) where !file.path.contains("/StowSync/Gmail/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("gmail.googleapis.com"), "\(file.lastPathComponent)")
            #expect(!text.contains("auth/gmail.modify") && !text.contains("auth/gmail.compose") && !text.contains("auth/gmail.send")
                && !text.contains("auth/gmail.insert"), "\(file.lastPathComponent)")
        }
    }
}

/// Archived Gmail mail in memory, by Gmail ID.
struct MemoryGmailSource: GmailMessageSource {
    var messages: [UInt64: Data]
    var threads: [UInt64: UInt64] = [:]
    func listGmailMessageIDs() async throws -> [UInt64] { messages.keys.sorted() }
    func readGmailMessage(_ id: UInt64) async throws -> Data { messages[id]! }
    func storedGmailThreadID(_ id: UInt64) async throws -> UInt64? { threads[id] }
}

/// Step 8 (D-593): `verify --server` for Gmail compares archived bytes with
/// the API's `raw` message, with the same sampling and report as IMAP.
@Suite struct GmailVerifyTests {
    static let archived: [UInt64: Data] = [
        0x11: Data("From: a\r\n\r\none\r\n".utf8),
        0x22: Data("From: b\r\n\r\ntwo\r\n".utf8),
        0x33: Data("From: c\r\n\r\nthree\r\n".utf8),
        0x44: Data("From: d\r\n\r\nfour\r\n".utf8),
    ]

    /// Gmail as the fake holds it: 0x22 differs by one byte, 0x44 is gone.
    static func gmail() -> FakeGmailTransport {
        FakeGmailTransport { request, _ in
            let id = request.url.path.components(separatedBy: "/").last ?? ""
            guard let number = UInt64(id, radix: 16), number != 0x44, var bytes = archived[number] else {
                return GmailHTTPResponse(status: 404, body: Data(#"{"error":{"code":404,"errors":[{"reason":"notFound"}]}}"#.utf8))
            }
            if number == 0x22 { bytes[bytes.count - 3] = UInt8(ascii: "O") }
            let raw = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return GmailHTTPResponse(status: 200, body: Data(#"{"id":"\#(id)","threadId":"\#(id)","raw":"\#(raw)"}"#.utf8))
        }
    }

    func verifier(_ transport: FakeGmailTransport) -> GmailStoreVerifier {
        GmailStoreVerifier(account: Account(id: gmailTestAccount, provider: .gmail, email: "sam@example.com", displayName: "Sam"),
                           client: gmailClient(transport), source: MemoryGmailSource(messages: Self.archived),
                           budget: ByteBudget(limit: nil, fileURL: nil))
    }

    @Test func allComparesEveryMessageAndNamesProblemsByGmailID() async throws {
        let transport = Self.gmail()
        let report = try await verifier(transport).run(sample: nil)
        #expect(report.storedMessages == 4 && report.sampled == 4)
        #expect(report.compared == 3 && report.identical == 2)
        #expect(report.mismatched == [.gmail(0x22)])
        #expect(report.goneFromServer == [.gmail(0x44)])
        #expect(!report.isClean)
        #expect(report.mismatched[0].description == "Gmail message 22")
        // Read-only: every request was a raw message get, and nothing else.
        let seen = await transport.seen
        #expect(seen.count == 4)
        #expect(seen.allSatisfy { $0.url.path.hasPrefix("/gmail/v1/users/me/messages/") && $0.url.query == "format=raw" })
    }

    @Test func sampleChecksOnlyThatMany() async throws {
        let transport = Self.gmail()
        let report = try await verifier(transport).run(sample: 2)
        #expect(report.storedMessages == 4 && report.sampled == 2)
        #expect(report.compared + report.goneFromServer.count == 2)
        #expect(await transport.seen.count == 2)
    }

    @Test func aCleanArchiveIsClean() async throws {
        let clean = FakeGmailTransport { request, _ in
            let id = request.url.path.components(separatedBy: "/").last ?? ""
            let bytes = Self.archived[UInt64(id, radix: 16)!]!
            let raw = bytes.base64EncodedString()
            return GmailHTTPResponse(status: 200, body: Data(#"{"id":"\#(id)","threadId":"\#(id)","raw":"\#(raw)"}"#.utf8))
        }
        let report = try await verifier(clean).run(sample: nil)
        #expect(report.isClean && report.identical == 4 && report.goneFromServer.isEmpty)
        #expect(report.threadIDsCompared == 0)
    }

    @Test func anUnusableReplyIsNotComparedAndTheRunCarriesOn() async throws {
        let flaky = FakeGmailTransport { request, _ in
            let id = request.url.path.components(separatedBy: "/").last ?? ""
            if id == "33" {
                return GmailHTTPResponse(status: 400, body: Data(#"{"error":{"code":400,"errors":[{"reason":"failedPrecondition"}]}}"#.utf8))
            }
            let raw = Self.archived[UInt64(id, radix: 16)!]!.base64EncodedString()
            return GmailHTTPResponse(status: 200, body: Data(#"{"id":"\#(id)","threadId":"\#(id)","raw":"\#(raw)"}"#.utf8))
        }
        let report = try await verifier(flaky).run(sample: nil)
        #expect(report.identical == 3 && report.notCompared == [.gmail(0x33)] && report.isClean)
    }

    /// The fake answers each message's own ID as its thread ID.
    @Test func storedThreadIDsAreComparedWithTheAPIs() async throws {
        let clean = FakeGmailTransport { request, _ in
            let id = request.url.path.components(separatedBy: "/").last ?? ""
            let raw = Self.archived[UInt64(id, radix: 16)!]!.base64EncodedString()
            return GmailHTTPResponse(status: 200, body: Data(#"{"id":"\#(id)","threadId":"\#(id)","raw":"\#(raw)"}"#.utf8))
        }
        let source = MemoryGmailSource(messages: Self.archived, threads: [0x11: 0x11, 0x22: 0x22, 0x33: 0x99])
        let verifier = GmailStoreVerifier(account: Account(id: gmailTestAccount, provider: .gmail, email: "sam@example.com", displayName: "Sam"),
                                          client: gmailClient(clean), source: source, budget: ByteBudget(limit: nil, fileURL: nil))
        let report = try await verifier.run(sample: nil)
        #expect(report.identical == 4 && report.threadIDsCompared == 3)
        #expect(report.threadIDMismatched == [.gmail(0x33)])
        #expect(!report.isClean)
    }
}
