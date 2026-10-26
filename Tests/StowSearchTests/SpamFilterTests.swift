import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// D-022: mail the user marked as spam in the mailbox is kept, but hidden from normal search.
@Suite(.serialized) struct SpamFilterTests {
    @Test func spamIsHiddenUnlessAskedFor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-spam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        let account = AccountID(rawValue: "00000000-0000-4000-8000-0000000000cc")
        try archive.register(Account(id: account, provider: .gmail, email: "sam@example.com", displayName: "S"))
        let importer = Importer(archive: archive)
        var ids: [StoredMessageID] = []
        for uid in 1...2 {
            let text = "From: a@example.org\r\nSubject: Quince \(uid)\r\nMessage-ID: <q\(uid)@example.org>\r\n\r\nquince marmalade\r\n"
            let raw = RawMessage(key: RawMessageKey(accountID: account, folder: "[Gmail]/All Mail", uidValidity: 1, uid: UInt32(uid)),
                                 internalDate: Date(), size: text.utf8.count, bytes: Data(text.utf8))
            if case .imported(let id) = try importer.importMessage(raw) { ids.append(id) }
        }
        let searcher = MessageSearcher(archive: archive)
        func subjects(_ query: String) async throws -> [String] {
            try await searcher.search(QueryParser.parse(query)).compactMap(\.subject).sorted()
        }
        #expect(try await subjects("quince") == ["Quince 1", "Quince 2"])

        let spam = ids[0]
        try await archive.database.write { db in
            try db.execute(sql: "UPDATE messages SET source_state = 'spam' WHERE id = ?", arguments: [spam])
        }
        #expect(try await subjects("quince") == ["Quince 2"])
        #expect(try await subjects("quince in:spam") == ["Quince 1"])
        #expect(try await subjects("quince in:anywhere") == ["Quince 1", "Quince 2"])
        #expect(try await subjects("in:spam") == ["Quince 1"])
        // Each hit says where it stands, so the app can mark spam rows (D-418).
        let states = try await searcher.search(QueryParser.parse("quince in:anywhere")).map { ($0.messageID, $0.sourceState) }
        #expect(Set(states.map { "\($0.0)=\($0.1.rawValue)" }) == ["\(ids[0])=spam", "\(ids[1])=present"])
        #expect(try await searcher.search(QueryParser.parse("in:anywhere")).count == 2)
        // The window's count for All accounts, with and without "Show spam too".
        #expect(try await searcher.count(SearchQuery(text: "")) == 1)
        #expect(try await searcher.count(SearchQuery(text: "", spam: .include)) == 2)
        #expect(try await searcher.count(SearchQuery(text: "", spam: .only)) == 1)
        #expect(QueryParser.parse("in:inbox quince").text == "quince")  // other in: values name a folder (D-079)
    }
}
