import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// R1 to R4 of the Phase 2 close-out (D-079): browsing with no text, folder and
/// label filters, total counts and the conversation around one message.
final class BrowseFixture: @unchecked Sendable {
    let root: URL
    let archive: Archive
    let searcher: MessageSearcher
    let microsoft = AccountID(rawValue: "00000000-0000-4000-8000-0000000000d1")
    let gmail = AccountID(rawValue: "00000000-0000-4000-8000-0000000000d2")
    private(set) var ids: [String: StoredMessageID] = [:]
    private var uid: UInt32 = 0

    /// Day `n` of September 2025, midnight UTC.
    static func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_756_684_800 + Double(n - 1) * 86_400) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-browse-\(UUID().uuidString)")
        archive = try Archive.open(ArchiveLocation(root: root),
                                   keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        try archive.register(Account(id: microsoft, provider: .microsoft, email: "sam@example.com", displayName: "Work"))
        try archive.register(Account(id: gmail, provider: .gmail, email: "sam@example.net", displayName: "Home"))
        searcher = MessageSearcher(archive: archive)

        // Microsoft: a thread rooted at <alpha@example.org>, across two folders, by References.
        try add("alpha1", account: microsoft, folder: "INBOX", day: 1, subject: "Alpha plans", messageID: "alpha@example.org")
        try add("alpha3", account: microsoft, folder: "INBOX", day: 3, subject: "Re: Alpha plans", references: "alpha@example.org")
        try add("alpha2", account: microsoft, folder: "Clients/Project X", day: 2, subject: "Re: Alpha plans", references: "alpha@example.org")
        try add("alphaSpam", account: microsoft, folder: "INBOX", day: 4, subject: "Re: Alpha plans", references: "alpha@example.org")
        try add("sent", account: microsoft, folder: "Sent Items", day: 5, subject: "Quarterly figures")
        try add("loner", account: microsoft, folder: "INBOX", day: 6, subject: "Lonely note")
        // Gmail: a thread by X-GM-THRID, with labels; one message whose References collide with Microsoft's thread.
        try add("gamma1", account: gmail, folder: "[Gmail]/All Mail", day: 1, subject: "Gamma figures", labels: ["\\Inbox"], thread: 77)
        try add("gamma2", account: gmail, folder: "[Gmail]/All Mail", day: 2, subject: "Re: Gamma figures",
                labels: ["Project X", "\\Sent"], thread: 77)
        try add("collide", account: gmail, folder: "[Gmail]/All Mail", day: 7, subject: "Alpha elsewhere", references: "alpha@example.org")

        try archive.database.write { db in
            try db.execute(sql: "UPDATE messages SET source_state = 'spam' WHERE id = ?", arguments: [self.ids["alphaSpam"]!])
            try db.execute(sql: "UPDATE folders SET special_use = '\\sent', delimiter = '/' WHERE name = 'Sent Items'")
            try db.execute(sql: "UPDATE folders SET special_use = '\\all' WHERE name = '[Gmail]/All Mail'")
            try db.execute(sql: "UPDATE folders SET delimiter = '/' WHERE name = 'Clients/Project X'")
            // Folders sync leaves out: Gmail's label folder for INBOX, and Microsoft's Junk.
            try db.execute(sql: """
                INSERT INTO folders (account_id, name, kind, skipped_reason) VALUES
                (?, 'INBOX', 'folder', 'label: its messages come from All Mail, with labels attached'),
                (?, 'Junk Email', 'folder', 'Spam: not archived')
                """, arguments: [gmail.rawValue, microsoft.rawValue])
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func add(_ name: String, account: AccountID, folder: String, day: Int, subject: String, messageID: String? = nil,
             references: String? = nil, labels: [String] = [], thread: UInt64? = nil) throws {
        uid += 1
        var text = "From: Alex <alex@example.org>\r\nTo: sam@example.com\r\nSubject: \(subject)\r\n"
        text += "Message-ID: <\(messageID ?? "\(name)@example.org")>\r\n"
        if let references { text += "References: <\(references)>\r\nIn-Reply-To: <\(references)>\r\n" }
        text += "\r\nfiller words about \(name)\r\n"
        let raw = RawMessage(key: RawMessageKey(accountID: account, folder: folder, uidValidity: 1, uid: uid), labels: labels,
                             gmailThreadID: thread, internalDate: Self.day(day), size: text.utf8.count, bytes: Data(text.utf8))
        guard case .imported(let id) = try Importer(archive: archive).importMessage(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ids[name] = id
    }

    func names(_ hits: [SearchHit]) -> [String] {
        hits.map { hit in ids.first { $0.value == hit.messageID }!.key }
    }

    func names(_ query: String) async throws -> [String] {
        names(try await searcher.search(QueryParser.parse(query)))
    }
}

@Suite(.serialized) struct BrowseAndThreadTests {
    let fixture: BrowseFixture

    init() throws { fixture = try BrowseFixture() }

    // MARK: R1

    @Test func emptyQueryListsEverythingNewestFirst() async throws {
        // Same day: the later import (higher ID) first.
        #expect(try await fixture.names("") == ["collide", "loner", "sent", "alpha3", "gamma2", "alpha2", "gamma1", "alpha1"])
        let all = try await fixture.searcher.search(SearchQuery(text: ""))
        #expect(all.count == 8)  // spam hidden
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.date >= $1.date })
        #expect(try await fixture.names("in:anywhere").count == 9)
        #expect(try await fixture.names("in:spam") == ["alphaSpam"])

        let page = try await fixture.searcher.search(SearchQuery(text: "", limit: 3, offset: 2))
        #expect(page.map(\.messageID) == Array(all.dropFirst(2).prefix(3)).map(\.messageID))
    }

    // MARK: R2

    @Test func folderAndLabelFilters() async throws {
        // A Microsoft folder by full path, and a Gmail label; with and without text.
        #expect(try await fixture.names("in:\"Clients/Project X\"") == ["alpha2"])
        #expect(try await fixture.names("in:\"project x\"") == ["gamma2"])
        #expect(try await fixture.names("in:\"Project X\" gamma") == ["gamma2"])
        #expect(try await fixture.names("in:\"Project X\" alpha").isEmpty)
        // in:inbox on both providers: Microsoft's INBOX folder and Gmail's \Inbox label. Spam stays hidden.
        #expect(Set(try await fixture.names("in:inbox")) == ["alpha1", "alpha3", "loner", "gamma1"])
        #expect(Set(try await fixture.names("in:inbox in:anywhere")) == ["alpha1", "alpha3", "loner", "gamma1", "alphaSpam"])
        #expect(try await fixture.names("in:inbox account:\(fixture.gmail.rawValue)") == ["gamma1"])
        // in:sent: Gmail's \Sent label and a Microsoft folder flagged \Sent.
        #expect(Set(try await fixture.names("in:sent")) == ["gamma2", "sent"])
        #expect(try await fixture.names("in:nowhere").isEmpty)
        // By ID, as the sidebar does.
        let folders = try await fixture.searcher.folders(accounts: [fixture.microsoft])
        let projectX = try #require(folders.first { $0.name == "Clients/Project X" })
        let byID = try await fixture.searcher.search(SearchQuery(text: "", place: .folder(projectX.id)))
        #expect(fixture.names(byID) == ["alpha2"])

        // Removed from the folder on the server: no longer matches it, still in the archive.
        try await fixture.archive.database.write { db in
            try db.execute(sql: "UPDATE message_folders SET removed_from_server_at = 1 WHERE folder_id = ?", arguments: [projectX.id])
        }
        #expect(try await fixture.names("in:\"Clients/Project X\"").isEmpty)
        #expect(try await fixture.names("").contains("alpha2"))
    }

    @Test func spamAndAnywhereWinOverFolderNames() throws {
        #expect(QueryParser.parse("in:spam").spam == .only)
        #expect(QueryParser.parse("in:spam").place == nil)
        #expect(QueryParser.parse("in:Anywhere").spam == .include)
        let query = QueryParser.parse("in:\"Project X\" report")
        #expect(query.place == .named("Project X"))
        #expect(query.text == "report")
    }

    @Test func folderListing() async throws {
        let folders = try await fixture.searcher.folders(accounts: [])
        let names = Set(folders.map { "\($0.accountID == fixture.gmail ? "g" : "m"):\($0.kind.rawValue):\($0.name)" })
        #expect(names == ["m:folder:INBOX", "m:folder:Clients/Project X", "m:folder:Sent Items",
                          "g:folder:[Gmail]/All Mail", "g:label:\\Inbox", "g:label:Project X", "g:label:\\Sent"])
        #expect(folders.first { $0.name == "Sent Items" }?.specialUse == "\\sent")
        #expect(folders.first { $0.name == "Clients/Project X" }?.delimiter == "/")
        #expect(try await fixture.searcher.folders(accounts: [fixture.gmail]).count == 4)
    }

    // MARK: R3

    @Test(arguments: ["", "alpha", "filler", "in:inbox", "in:inbox filler", "in:anywhere", "in:spam", "in:\"Project X\"",
                      "after:2025-09-02 before:2025-09-05", "from:alex", "zzznotaword", "in:nowhere"])
    func countMatchesEveryPage(query: String) async throws {
        var parsed = QueryParser.parse(query, limit: 3)
        var seen: [StoredMessageID] = []
        while true {
            let page = try await fixture.searcher.search(parsed)
            seen += page.map(\.messageID)
            if page.count < parsed.limit { break }
            parsed.offset += parsed.limit
        }
        #expect(Set(seen).count == seen.count)
        #expect(try await fixture.searcher.count(QueryParser.parse(query)) == seen.count, "\(query)")
    }

    // MARK: R4

    @Test func threadAroundOneMessage() async throws {
        let ids = fixture.ids
        // References-based, across folders, oldest first by arrival; spam member left out; Gmail collision kept apart.
        let thread = try #require(try await fixture.searcher.thread(of: ids["alpha3"]!))
        #expect(thread.messages.map(\.messageID) == [ids["alpha1"]!, ids["alpha2"]!, ids["alpha3"]!])
        #expect(thread.selectedIndex == 2)
        #expect(thread.totalCount == 3)
        #expect(!thread.truncated)
        #expect(thread.accountID == fixture.microsoft)
        #expect(thread.threadKey == "m:alpha@example.org")
        #expect(thread.messages[0].subject == "Alpha plans")
        #expect(thread.messages[0].from?.address == "alex@example.org")

        // Asked about the spam message itself: every member, spam marked.
        let spam = try #require(try await fixture.searcher.thread(of: ids["alphaSpam"]!))
        #expect(spam.messages.count == 4)
        #expect(spam.messages[spam.selectedIndex].sourceState == .spam)

        // Gmail thread by X-GM-THRID.
        let gamma = try #require(try await fixture.searcher.thread(of: ids["gamma1"]!))
        #expect(gamma.messages.map(\.messageID) == [ids["gamma1"]!, ids["gamma2"]!])
        #expect(gamma.selectedIndex == 0)

        // Same m: key in the other account: a thread of one.
        let collide = try #require(try await fixture.searcher.thread(of: ids["collide"]!))
        #expect(collide.messages.map(\.messageID) == [ids["collide"]!])

        // No thread key at all: a thread of one. Unknown ID: nil.
        try await fixture.archive.database.write { db in
            try db.execute(sql: "UPDATE messages SET thread_key = NULL WHERE id = ?", arguments: [ids["loner"]!])
        }
        let loner = try #require(try await fixture.searcher.thread(of: ids["loner"]!))
        #expect(loner.messages.count == 1 && loner.selectedIndex == 0 && loner.threadKey == nil)
        #expect(try await fixture.searcher.thread(of: 999_999) == nil)
    }

    @Test func longThreadIsCappedAroundTheMessage() async throws {
        let size = MessageThread.maximumMessages
        for n in 0..<(size + 40) {
            try fixture.add("long\(n)", account: fixture.microsoft, folder: "INBOX", day: 10, subject: "Long \(n)",
                            references: "long-root@example.org")
        }
        let ids = fixture.ids
        let early = try #require(try await fixture.searcher.thread(of: ids["long3"]!))
        #expect(early.messages.count == size && early.totalCount == size + 40 && early.truncated)
        #expect(early.messages.first?.messageID == ids["long0"])
        #expect(early.selectedIndex == 3)

        let middle = try #require(try await fixture.searcher.thread(of: ids["long270"]!))
        #expect(middle.messages[middle.selectedIndex].messageID == ids["long270"])
        #expect(middle.selectedIndex == size / 2)

        let last = try #require(try await fixture.searcher.thread(of: ids["long\(size + 39)"]!))
        #expect(last.messages.last?.messageID == ids["long\(size + 39)"])
        #expect(last.selectedIndex == size - 1)
    }
}
