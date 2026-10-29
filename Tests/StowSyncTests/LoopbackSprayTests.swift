import Foundation
import Testing
@testable import StowSync

/// A-06: only a reply carrying this sign-in's state ends it. Anything else a
/// page in any browser can send to 127.0.0.1 gets 400 and the listener keeps
/// waiting, so a spray across the port range cannot cancel a sign-in.
@Suite struct LoopbackSprayTests {
    static func get(_ listener: LoopbackListener, _ path: String) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession(configuration: .ephemeral)
            .data(from: URL(string: "http://127.0.0.1:\(listener.port)\(path)")!)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test(arguments: [
        "/?error=access_denied",
        "/?error=access_denied&state=wrong",
        "/?code=stolen&state=wrong",
        "/?code=stolen",
        "/",
        "/other?code=the-code&state=expected",
    ])
    func aReplyWithoutTheRightStateDoesNotEndTheSignIn(path: String) async throws {
        let listener = try await LoopbackListener.start(expectedState: "expected", timeout: 30)
        defer { listener.close() }
        let rejected = try await Self.get(listener, path)
        #expect(rejected.status == 400 || (path.hasPrefix("/other") && rejected.status == 404))
        #expect(!listener.isClosed)
        // The page says nothing about the sign-in and echoes nothing.
        for word in ["sign", "Sign", "access_denied", "stolen", "wrong", "expected", "state"] {
            #expect(!rejected.body.contains(word), "page contains \(word)")
        }
        #expect(try await Self.get(listener, "/?code=the-code&state=expected").status == 200)
        #expect(try await listener.waitForCode() == "the-code")
        #expect(listener.isClosed)
    }

    @Test func manyRejectedRepliesThenTheRealOne() async throws {
        let listener = try await LoopbackListener.start(expectedState: "expected", timeout: 30)
        defer { listener.close() }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<50 {
                group.addTask { try await Self.get(listener, "/?error=x\(index)").status }
            }
            for try await status in group { #expect(status == 400) }
        }
        #expect(try await Self.get(listener, "/?code=c&state=expected").status == 200)
        #expect(try await listener.waitForCode() == "c")
    }

    @Test func theProvidersOwnErrorWithTheRightStateEndsIt() async throws {
        let listener = try await LoopbackListener.start(expectedState: "expected", timeout: 30)
        #expect(try await Self.get(listener, "/?error=access_denied&error_description=private&state=expected").status == 400)
        await #expect(throws: LoopbackError.providerError("access_denied")) { _ = try await listener.waitForCode() }
        #expect(listener.isClosed)
    }

    @Test func theRightStateWithoutACodeEndsIt() async throws {
        let listener = try await LoopbackListener.start(expectedState: "expected", timeout: 30)
        #expect(try await Self.get(listener, "/?state=expected").status == 400)
        await #expect(throws: LoopbackError.missingCode) { _ = try await listener.waitForCode() }
    }

    @Test func afterAFinishFurtherRequestsAreRefusedOrUnanswered() async throws {
        let listener = try await LoopbackListener.start(expectedState: "expected", timeout: 30)
        #expect(try await Self.get(listener, "/?code=c&state=expected").status == 200)
        #expect(try await listener.waitForCode() == "c")
        // The listener is cancelled: a later request either fails to connect or gets 503.
        if let late = try? await Self.get(listener, "/?code=c&state=expected") {
            #expect(late.status == 503)
        }
    }

    @Test func withNoMatchingReplyItEndsAtItsTimeout() async throws {
        let listener = try await LoopbackListener.start(expectedState: "expected", timeout: 1)
        #expect(try await Self.get(listener, "/?error=access_denied").status == 400)
        #expect(try await Self.get(listener, "/?code=x&state=wrong").status == 400)
        await #expect(throws: LoopbackError.timedOut) { _ = try await listener.waitForCode() }
    }
}
