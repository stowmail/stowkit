import Foundation
import NIOIMAP
import StowCore
import Testing
@testable import StowSync

/// A-13 (security sweep 1): what a mail server sends in reply to one command
/// is bounded in UIDs, bytes and time (D-496).
@Suite(.serialized, .timeLimit(.minutes(1))) struct IMAPBoundsTests {
    static func server() -> FakeIMAPServer {
        FakeIMAPServer(mailboxes: [
            .init(name: "INBOX", attributes: [], uidValidity: 1, messages: (1...3).map {
                .init(uid: UInt32($0), bytes: Data("Subject: \($0)\r\nMessage-ID: <\($0)@example.org>\r\n\r\nbody\r\n".utf8))
            }),
        ])
    }

    static func open(_ server: FakeIMAPServer, command: TimeInterval = 300) async throws -> IMAPSession {
        let port = try await server.start()
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)),
                                                    timeouts: IMAPTimeouts(connect: 5, read: 90, command: command))
        try await session.authenticate(user: "sam@example.com", accessToken: "good-token")
        let inbox = try #require(try await session.listFolders().first { $0.name == "INBOX" })
        _ = try await session.examine(inbox)
        return session
    }

    @Test func unrequestedUIDsAreDroppedAsTheyArrive() async throws {
        let server = Self.server()
        defer { server.stop() }
        let session = try await Self.open(server)
        server.unrequestedFetches = (2000, 0)
        #expect(try await session.fetchStates(1...3, gmail: false).map(\.uid) == [1, 2, 3])
        #expect(try await session.fetchUIDs([2]).map(\.uid) == [2])
        server.unrequestedFetches = (50, 1000)
        let reply = try await session.fetchMessagesWithDiagnostics(uids: [1, 3], gmail: false)
        #expect(reply.messages.map(\.uid) == [1, 3])
        #expect(await session.droppedResponses == 4050)
    }

    /// Memory does not grow with responses nobody asked for.
    @Test func assemblerKeepsOnlyWhatWasAskedFor() throws {
        var assembler = FetchAssembler(wanted: .uids([7]), byteLimit: 1 << 20)
        for uid in UInt32(1)...100_000 {
            try assembler.consume(.fetch(.start(SequenceNumber(rawValue: uid))))
            try assembler.consume(.fetch(.simpleAttribute(.uid(UID(rawValue: uid)))))
            try assembler.consume(.fetch(.finish))
        }
        #expect(assembler.finished.map(\.uid) == [7])
        #expect(assembler.dropped == 99_999)
    }

    @Test func replyOverTheByteCapFailsTheCommand() async throws {
        let server = Self.server()
        defer { server.stop() }
        let session = try await Self.open(server)
        server.unrequestedFetches = (40, 1 << 20) // 40 MB of bodies nobody asked for
        do {
            _ = try await session.fetchMessagesWithDiagnostics(uids: [1], gmail: false, expectedBytes: 100)
            Issue.record("a 40 MB reply to a 100-byte request was accepted")
        } catch let error as SyncError {
            guard case .connectionClosed(let text?) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(text.contains("byte limit"))
            #expect(error.isRetryable)
        }
    }

    @Test func slowTrickleFailsAtTheDeadline() async throws {
        let server = Self.server()
        defer { server.stop() }
        let session = try await Self.open(server, command: 1)
        server.trickleInterval = 0.1 // about 15 s for the reply; the 90 s idle timer never trips
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await session.fetchStates(1...3, gmail: false)
            Issue.record("the trickled reply was waited out")
        } catch let error as SyncError {
            guard case .connectionClosed(let text?) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(text.contains("took longer than"))
            #expect(error.isRetryable)
        }
        #expect(clock.now - start < .seconds(5))
    }
}
