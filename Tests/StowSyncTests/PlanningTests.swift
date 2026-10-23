import Foundation
import NIOIMAPCore
import StowCore
import Testing
@testable import StowSync

@Suite struct BatchPlannerTests {
    func summaries(_ sizes: [Int]) -> [MessageSummary] {
        sizes.enumerated().map { MessageSummary(uid: UInt32($0.offset + 1), size: $0.element) }
    }

    @Test func splitsByCountAndBytes() {
        let planner = BatchPlanner(maxMessages: 3, maxBytes: 100)
        #expect(planner.batches([]).isEmpty)
        #expect(planner.batches(summaries([10, 10, 10, 10])).map { $0.map(\.uid) } == [[1, 2, 3], [4]])
        #expect(planner.batches(summaries([60, 50, 10])).map { $0.map(\.uid) } == [[1], [2, 3]])
        // A message bigger than the byte cap still gets a batch of its own.
        #expect(planner.batches(summaries([10, 500, 10])).map { $0.map(\.uid) } == [[1], [2], [3]])
    }

    @Test func defaultsMatchTheBrief() {
        #expect(BatchPlanner().maxMessages == 100)
    }
}

@Suite struct FolderPlannerTests {
    func folder(_ name: String, _ attributes: String...) -> IMAPFolder {
        IMAPFolder(name: name, rawName: Array(name.utf8), separator: "/", attributes: Set(attributes))
    }

    @Test func gmailUsesTheAllFolderWhateverItIsCalled() throws {
        let folders = [folder("INBOX"), folder("[Gmail]", "\\Noselect"), folder("[Gmail]/Alle Nachrichten", "\\All"),
                       folder("[Gmail]/Spam", "\\Junk"), folder("[Gmail]/Papierkorb", "\\Trash"), folder("Work")]
        let plan = try FolderPlanner.plan(provider: .gmail, folders: folders, capabilities: ["X-GM-EXT-1"])
        #expect(plan.toSync.map(\.name) == ["[Gmail]/Alle Nachrichten"])
        #expect(plan.skipped.count == 5)
        #expect(plan.skipped.first { $0.folder.name == "[Gmail]/Spam" }?.reason.contains("D-104") == true)
    }

    @Test func gmailWithoutExtensionsOrAllMailFails() {
        #expect(throws: SyncError.self) {
            try FolderPlanner.plan(provider: .gmail, folders: [folder("x", "\\All")], capabilities: [])
        }
        #expect(throws: SyncError.allMailNotFound) {
            try FolderPlanner.plan(provider: .gmail, folders: [folder("INBOX")], capabilities: ["X-GM-EXT-1"])
        }
    }

    @Test func microsoftSkipsNoselectAndJunkOnly() throws {
        let folders = [folder("INBOX"), folder("Deleted Items", "\\Trash"), folder("Junk Email", "\\Junk"),
                       folder("Parent", "\\NoSelect"), folder("Gone", "\\NonExistent"), folder("Sent Items", "\\Sent")]
        let plan = try FolderPlanner.plan(provider: .microsoft, folders: folders, capabilities: [])
        #expect(plan.toSync.map(\.name) == ["INBOX", "Deleted Items", "Sent Items"])
        #expect(Set(plan.skipped.map(\.folder.name)) == ["Junk Email", "Parent", "Gone"])
    }

    /// D-112: Exchange's non-mail folders are skipped; look-alike user folders are not.
    @Test func microsoftSkipsExchangeNonMailFolders() throws {
        let folders = [
            folder("INBOX"), folder("Calendar"), folder("Calendar/Birthdays"), folder("Calendar/UK holidays"),
            folder("Contacts"), folder("Contacts/Recipient Cache"), folder("Journal"), folder("Notes"), folder("Tasks"),
            folder("Conversation History"), folder("Outbox"), folder("CALENDAR/Shouty"),
            // Look-alikes that are user mail folders and must sync:
            folder("Work/Calendar"), folder("Calendar invites"), folder("Notes from meetings"), folder("Archive/Tasks"),
            folder("Taskforce"), folder("Gym", "\\HasNoChildren"),
            // Attribute-based, whatever the name:
            folder("Agenda", "\\Calendar"),
        ]
        let plan = try FolderPlanner.plan(provider: .microsoft, folders: folders, capabilities: [])
        #expect(plan.toSync.map(\.name) == ["INBOX", "Work/Calendar", "Calendar invites", "Notes from meetings", "Archive/Tasks", "Taskforce", "Gym"])
        let skipped = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.folder.name, $0.reason) })
        #expect(skipped.count == 12)
        #expect(skipped["Calendar/Birthdays"]?.contains("D-112") == true)
        #expect(skipped["Agenda"]?.contains("\\calendar") == true)
        // Gmail is not affected: a Gmail label called Calendar is just a label.
        #expect(FolderPlanner.nonMailReason(folder("Calendar")) != nil)
    }

    @Test func folderDescriptionHidesTheName() {
        #expect(!String(describing: folder("Private matters", "\\HasNoChildren")).contains("Private"))
    }
}

@Suite struct ByteBudgetTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    @Test func rollingWindowAndPersistence() async throws {
        let clock = Clock()
        let file = temporaryDirectory().appendingPathComponent("budget.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let budget = ByteBudget(limit: 1_000, fileURL: file, now: { clock.now })
        #expect(await budget.allows(1_000))
        try await budget.record(600)
        #expect(await budget.used() == 600)
        #expect(await budget.allows(400))
        #expect(!(await budget.allows(401)))

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        clock.now = clock.now.addingTimeInterval(23 * 3600)
        try await budget.record(300)
        let reloaded = ByteBudget(limit: 1_000, fileURL: file, now: { clock.now })
        #expect(await reloaded.used() == 900)

        clock.now = clock.now.addingTimeInterval(2 * 3600) // the first spend is now over 24 hours old
        #expect(await reloaded.used() == 300)
    }

    @Test func noLimitAlwaysAllows() async {
        let budget = ByteBudget(limit: nil, fileURL: nil)
        #expect(await budget.allows(Int64.max / 2))
    }

    @Test func gmailLimitStaysUnderGooglesCap() {
        #expect(ProviderProfile.gmail.dailyByteLimit == 2_000_000_000)
        #expect(ProviderProfile.gmail.maxConnections <= 3)
        #expect(ProviderProfile.microsoft.dailyByteLimit == nil)
        #expect((1...2).contains(ProviderProfile.microsoft.maxConnections))
        #expect(ProviderProfile.gmail.endpoint == IMAPEndpoint(host: "imap.gmail.com", port: 993))
        #expect(ProviderProfile.microsoft.endpoint == IMAPEndpoint(host: "outlook.office365.com", port: 993))
        #expect(ProviderProfile.gmail.endpoint.useTLS && ProviderProfile.microsoft.endpoint.useTLS)
    }
}

@Suite struct RetryPolicyTests {
    @Test func doublesUpToFiveMinutes() {
        let policy = RetryPolicy()
        #expect((1...10).map { policy.delay(forAttempt: $0) } == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        #expect(policy.maxAttempts == 5)
    }
}

/// Security checklist: "Session API offers no write commands".
@Suite struct ReadOnlyGuaranteeTests {
    /// Every command the session can build, mapped back to its IMAP verb.
    @Test func everyCommandIsReadOnly() {
        let all: [ReadOnlyCommand] = [
            .capability, .authenticateXOAUTH2(user: "u@example.com", accessToken: "t"), .listAll,
            .examine(rawName: Array("INBOX".utf8)), .fetchSummaries(1...10), .fetchSummariesOf(uids: [4, 9]), .fetchMessages(uids: [1, 2, 5], gmail: true), .logout,
        ]
        for command in all {
            switch command.command {
            case .capability, .authenticate, .list, .examine, .logout:
                break
            case .uidFetch(_, let attributes, _):
                for attribute in attributes {
                    if case .bodySection(let peek, _, _) = attribute { #expect(peek, "body fetch without PEEK") }
                    #expect(attribute != .rfc822 && attribute != .rfc822Text, "RFC822 fetch sets \\Seen")
                    if case .binary(let peek, _, _) = attribute { #expect(peek) }
                }
            default:
                Issue.record("Command outside the read-only list: \(command.verb)")
            }
        }
    }

    @Test func uidSetsCollapseIntoRanges() {
        let set = ReadOnlyCommand.uidSet([7, 1, 2, 3, 9, 8, 2])
        #expect(set.set.ranges.map { "\($0.lowerBound.rawValue):\($0.upperBound.rawValue)" } == ["1:3", "7:9"])
    }

    @Test func xoauth2StringHasTheRightShape() {
        let bytes = XOAUTH2.initialResponse(user: "sam@example.com", accessToken: "tok")
        #expect(String(decoding: bytes, as: UTF8.self) == "user=sam@example.com\u{01}auth=Bearer tok\u{01}\u{01}")
    }

    /// Belt and braces: no source file that talks IMAP (StowSync/IMAP and
    /// StowSync/Sync) names a mailbox-changing command or a non-PEEK body fetch.
    /// (Keychain code elsewhere legitimately calls `.delete(`.)
    @Test func sourceNamesNoWriteCommand() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StowSync")
        let forbidden = [".select(", ".store(", ".uidStore(", ".expunge", ".uidExpunge(", ".copy(", ".uidCopy(", ".move(",
                         ".uidMove(", ".append(", ".create(", ".delete(", ".rename(", ".subscribe(", ".setMetadata(",
                         "peek: false", ".rfc822,", ".rfc822]", "AppendCommand", ".idleStart"]
        let files = ["IMAP", "Sync"].flatMap { folder in
            FileManager.default.enumerator(at: sources.appendingPathComponent(folder), includingPropertiesForKeys: nil)!
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        #expect(files.count >= 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden where word != ".append(" {
                #expect(!text.contains(word), "\(file.lastPathComponent) contains \(word)")
            }
            // `.append(` is fine on arrays; only an IMAP APPEND command is forbidden.
            #expect(!text.contains("Command.append") && !text.contains(".append(AppendCommand"), "\(file.lastPathComponent)")
        }
    }

    @Test func plaintextIsLoopbackOnly() {
        #expect(IMAPEndpoint.plaintextLoopback(port: 1143).host == "127.0.0.1")
        #expect(!IMAPEndpoint.plaintextLoopback(port: 1143).useTLS)
        #expect(IMAPEndpoint(host: "imap.example.com").useTLS)
    }
}
