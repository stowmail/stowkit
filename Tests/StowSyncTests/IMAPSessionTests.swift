import Foundation
import StowCore
import Testing
@testable import StowSync

/// A Microsoft-like mailbox: INBOX holding the given messages, plus an empty
/// Junk Email (`\Junk`, never synced) and Deleted Items (`\Trash`, synced),
/// as `FolderPlanner.planMicrosoft` expects. UIDs are sparse, as on a real server.
func microsoftServer(_ fixtures: [(name: String, bytes: Data)], uidValidity: UInt32 = 7) -> FakeIMAPServer {
    let messages = fixtures.enumerated().map { index, fixture in
        FakeIMAPServer.Message(uid: UInt32(index * 2 + 3), bytes: fixture.bytes)
    }
    let server = FakeIMAPServer(mailboxes: [
        .init(name: "INBOX", attributes: ["\\HasNoChildren"], uidValidity: uidValidity, messages: messages),
        .init(name: "Junk Email", attributes: ["\\HasNoChildren", "\\Junk"], uidValidity: 4, messages: []),
        .init(name: "Deleted Items", attributes: ["\\HasNoChildren", "\\Trash"], uidValidity: 5, messages: []),
    ])
    server.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR", "UIDPLUS"]
    return server
}

/// Commands that change a mailbox. None may ever reach a server.
let writeVerbs = ["SELECT", "STORE", "EXPUNGE", "MOVE", "COPY", "APPEND", "DELETE", "CREATE", "RENAME", "SUBSCRIBE", "UNSUBSCRIBE", "CLOSE", "SETMETADATA", "SETQUOTA"]

func assertReadOnly(_ log: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for line in log {
        let words = line.uppercased().split(separator: " ").dropFirst().prefix(2).map(String.init)
        for verb in writeVerbs {
            #expect(!words.contains(verb), "write command sent: \(line)", sourceLocation: sourceLocation)
        }
        if line.uppercased().contains("FETCH") {
            #expect(!line.uppercased().contains("BODY[]"), "non-PEEK body fetch: \(line)", sourceLocation: sourceLocation)
            #expect(!line.uppercased().contains("RFC822 ") && !line.uppercased().contains("RFC822)"), sourceLocation: sourceLocation)
        }
    }
}

@Suite struct IMAPSessionTests {
    @Test func readOnlyConversationAgainstAMicrosoftLikeServer() async throws {
        let fixtures = try Fixtures.small()
        let server = microsoftServer(fixtures)
        let port = try await server.start()
        defer { server.stop() }

        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        try await session.authenticate(user: "sam@example.com", accessToken: "good-token")
        let capabilities = try await session.capabilities()
        #expect(capabilities.contains("UIDPLUS") && !capabilities.contains("X-GM-EXT-1"))

        let folders = try await session.listFolders()
        #expect(folders.count == 3)
        let inbox = try #require(folders.first { $0.name == "INBOX" })
        #expect(inbox.separator == "/")
        #expect(folders.first { $0.has("\\Junk") }?.name == "Junk Email")
        #expect(folders.first { $0.has("\\Trash") }?.name == "Deleted Items")

        let status = try await session.examine(inbox)
        #expect(status.uidValidity == 7)
        #expect(status.exists == fixtures.count)
        #expect(status.uidNext == UInt32((fixtures.count - 1) * 2 + 3 + 1))

        let summaries = try await session.fetchUIDs(1...(status.uidNext! - 1))
        #expect(summaries.map(\.uid) == (0..<fixtures.count).map { UInt32($0 * 2 + 3) })
        #expect(summaries.map(\.size) == fixtures.map(\.bytes.count))

        let fetched = try await session.fetchMessages(uids: [3, 5, 7])
        #expect(fetched.map(\.uid) == [3, 5, 7])
        for (index, message) in fetched.enumerated() {
            #expect(message.bytes == fixtures[index].bytes) // byte for byte
            #expect(message.size == fixtures[index].bytes.count)
        }
        #expect(fetched[0].internalDate == Date(timeIntervalSince1970: 1_721_209_465)) // 17-Jul-2024 02:44:25 -0700

        await session.logout()

        let log = server.commandLog
        assertReadOnly(log)
        // Gmail's X-GM-* items went with Gmail's IMAP path (D-601): no fetch asks for them.
        #expect(!log.contains { $0.uppercased().contains("X-GM-") })
        #expect(log.contains { $0.contains("EXAMINE") })
        #expect(log.contains { $0.uppercased().contains("BODY.PEEK[]") })
        #expect(log.contains { $0.contains("AUTHENTICATE XOAUTH2 [redacted]") })
    }

    /// "n:*" style listing can return the last message even when its UID is below n.
    @Test func listingAboveTheHighestUIDReturnsNothing() async throws {
        let server = microsoftServer(try Fixtures.small())
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        try await session.authenticate(user: "sam@example.com", accessToken: "good-token")
        let inbox = try #require(try await session.listFolders().first { $0.name == "INBOX" })
        _ = try await session.examine(inbox)
        #expect(try await session.fetchUIDs(10_000...UInt32.max).isEmpty)
        await session.logout()
    }

    @Test func largeFixtureRoundTripsByteForByte() async throws {
        let fixtures = try Fixtures.all()
        let big = try #require(fixtures.first { $0.bytes.count > 15_000_000 })
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "Inbox", attributes: [], uidValidity: 1, messages: [.init(uid: 1, bytes: big.bytes)]),
        ])
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        try await session.authenticate(user: "sam@example.com", accessToken: "good-token")
        _ = try await session.examine(try #require(try await session.listFolders().first))
        let fetched = try await session.fetchMessages(uids: [1])
        #expect(fetched.count == 1)
        #expect(fetched.first?.bytes == big.bytes)
        await session.logout()
    }

    @Test func rejectedTokenIsAnAuthenticationFailure() async throws {
        let server = microsoftServer([])
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        await #expect {
            try await session.authenticate(user: "sam@example.com", accessToken: "revoked-token")
        } throws: { error in
            guard case SyncError.authenticationFailed(let text) = error else { return false }
            return text.contains("NO") && !text.contains("revoked-token")
        }
        await session.disconnect()
    }

    @Test func refusesAnExamineThatIsNotReadOnly() async throws {
        let server = microsoftServer(try Fixtures.small())
        server.examineAnswersReadWrite = true
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        try await session.authenticate(user: "sam@example.com", accessToken: "good-token")
        let inbox = try #require(try await session.listFolders().first { $0.name == "INBOX" })
        await #expect(throws: SyncError.protocolViolation("EXAMINE was not confirmed as read-only")) {
            _ = try await session.examine(inbox)
        }
        await session.disconnect()
    }

    @Test func droppedConnectionIsRetryable() async throws {
        let server = microsoftServer(try Fixtures.small())
        server.dropOnBodyFetchNumber = 1
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        try await session.authenticate(user: "sam@example.com", accessToken: "good-token")
        _ = try await session.examine(try #require(try await session.listFolders().first { $0.name == "INBOX" }))
        do {
            _ = try await session.fetchMessages(uids: [3])
            Issue.record("expected the connection to drop")
        } catch let error as SyncError {
            #expect(error.isRetryable)
        }
    }

    @Test func silentServerTimesOut() async throws {
        // The OAuth listener accepts connections and says nothing until it gets an HTTP request.
        let silent = try await LoopbackListener.start(expectedState: "x", timeout: 30)
        defer { silent.close() }
        await #expect(throws: SyncError.timedOut) {
            _ = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(silent.port)), timeouts: IMAPTimeouts(connect: 5, read: 0.5))
        }
    }

    @Test func closedPortIsAConnectionFailure() async throws {
        await #expect {
            _ = try await IMAPSession.connect(to: .plaintextLoopback(port: 1), timeouts: IMAPTimeouts(connect: 2, read: 1))
        } throws: { error in
            (error as? SyncError)?.isRetryable == true
        }
    }

    @Test func classifiesServerReplies() {
        #expect(IMAPSession.classifyBye("[OVERQUOTA] Account exceeded command or bandwidth limits") == .quotaExceeded("[OVERQUOTA] Account exceeded command or bandwidth limits"))
        #expect(IMAPSession.classifyBye("Request is throttled. Suggested Backoff Time: 1000 milliseconds").isRetryable)
        #expect(IMAPSession.classifyBye("System error").isRetryable)
        #expect(IMAPSession.classifyBye(nil) == .connectionClosed(nil))
        #expect(!SyncError.quotaExceeded("x").isRetryable)
        #expect(!SyncError.authenticationFailed("x").isRetryable)
    }
}
