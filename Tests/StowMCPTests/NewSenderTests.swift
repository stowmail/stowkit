import Foundation
import MCP
import StowCore
import Testing
@testable import StowMCP
@testable import StowSearch
@testable import StowStore

/// D-486 (2): a message whose sender's domain is new to the conversation is flagged.
@Suite struct NewSenderTests {
    func makeThread() throws -> MCPFixture {
        let fixture = try MCPFixture()
        try fixture.enable(fixture.work)
        // "first" (alex@example.org, to sam@work.example, cc kim@example.org) is in the fixture already;
        // "reply" (alex again) follows it. Then a reply from Sam, and a stranger joining through References.
        try fixture.add("sam-reply", account: fixture.work, hour: 6, subject: "Re: Boiler service", references: "boiler@example.org",
                        from: "Sam <sam@work.example>", body: "Thanks.")
        try fixture.add("kim-reply", account: fixture.work, hour: 7, subject: "Re: Boiler service", references: "boiler@example.org",
                        from: "Kim <KIM@Example.ORG>", body: "Noted.")
        try fixture.add("stranger", account: fixture.work, hour: 8, subject: "Re: Boiler service", references: "boiler@example.org",
                        from: "Billing <accounts@examp1e.net>", body: "Please pay the new account below.")
        return fixture
    }

    @Test func aStrangersReplyIsFlaggedAndTheOthersAreNot() async throws {
        let fixture = try makeThread()
        let reader = MessageReader(archive: fixture.archive)
        for (name, expected) in [("first", false), ("reply", false), ("sam-reply", false), ("kim-reply", false), ("stranger", true)] {
            let detail = try #require(try await reader.message(fixture.ids[name]!, bodyLimit: 100))
            #expect(detail.senderDomainNewToThread == expected, "\(name)")
        }
    }

    @Test func getThreadSaysSo() async throws {
        let fixture = try makeThread()
        let thread = await fixture.call("get_thread", ["message_id": .int(Int(fixture.ids["stranger"]!)), "bodies": 10])
        let lines = thread.text.split(separator: "\n").map(String.init)
        #expect(lines.filter { $0.contains("is new to this conversation") } == ["Sender's domain examp1e.net is new to this conversation."])
        let flag = try #require(lines.firstIndex { $0.contains("is new to this conversation") })
        #expect(lines[flag - 1].hasPrefix("From: Billing <accounts@examp1e.net>"))
    }

    @Test func theFlagDecodesAsFalseWhenMissing() throws {
        let detail = MessageDetail(messageID: 1, accountID: AccountID(rawValue: "a"), threadKey: nil, date: Date(timeIntervalSince1970: 0),
                                   sentDate: nil, from: nil, to: [], cc: [], subject: nil, sourceState: .present, body: nil,
                                   bodyFromHTML: false, bodyLength: 0, bodyTruncated: false, attachments: [], senderDomainNewToThread: true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as! [String: Any]
        #expect(json["senderDomainNewToThread"] as? Bool == true)
        json.removeValue(forKey: "senderDomainNewToThread")
        let old = try JSONDecoder().decode(MessageDetail.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.senderDomainNewToThread)
    }
}

/// D-486 (2): the flag's cost on a long conversation. Prints its figures.
@Suite struct NewSenderTimingTests {
    @Test func aLongThread() async throws {
        let fixture = try MCPFixture()
        try fixture.enable(fixture.work)
        for n in 0..<500 {
            try fixture.add("t\(n)", account: fixture.work, hour: 10 + n, subject: "Re: Boiler service", references: "boiler@example.org",
                            from: n % 50 == 49 ? "New <n\(n)@domain\(n).example>" : "Alex Hart <alex@example.org>", body: "Message \(n).")
        }
        let reader = MessageReader(archive: fixture.archive)
        var start = Date()
        var flagged = 0
        for n in 0..<500 where try await reader.message(fixture.ids["t\(n)"]!, bodyLimit: 1_000)!.senderDomainNewToThread { flagged += 1 }
        let readAll = Date().timeIntervalSince(start)
        start = Date()
        let thread = await fixture.call("get_thread", ["message_id": .int(Int(fixture.ids["t499"]!)), "bodies": 20])
        let getThread = Date().timeIntervalSince(start)
        print(String(format: "NEWSENDER 500-message thread: read every message %.3f s, get_thread on the last %.3f s, %d flagged", readAll, getThread, flagged))
        #expect(flagged == 10)
        #expect(!thread.isError)
        #expect(readAll < 5)
    }
}
