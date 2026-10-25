import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// R5: senders for the From token (D-057, D-403).
struct SenderSuggestionTests {
    final class Fixture: @unchecked Sendable {
        let root: URL
        let archive: Archive
        let searcher: MessageSearcher
        let work = AccountID(rawValue: "00000000-0000-4000-8000-0000000000e1")
        let home = AccountID(rawValue: "00000000-0000-4000-8000-0000000000e2")
        private var uid: UInt32 = 0

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-senders-\(UUID().uuidString)")
            archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
            try archive.register(Account(id: work, provider: .microsoft, email: "sam@example.com", displayName: "Work"))
            try archive.register(Account(id: home, provider: .gmail, email: "sam@example.net", displayName: "Home"))
            searcher = MessageSearcher(archive: archive)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func add(from: String, account: AccountID) throws -> StoredMessageID {
            uid += 1
            let text = "From: \(from)\r\nTo: sam@example.com\r\nSubject: Note \(uid)\r\nMessage-ID: <m\(uid)@example.org>\r\n\r\nhello\r\n"
            let raw = RawMessage(key: RawMessageKey(accountID: account, folder: "INBOX", uidValidity: 1, uid: uid),
                                 internalDate: Date(timeIntervalSince1970: 1_756_684_800 + Double(uid) * 60),
                                 size: text.utf8.count, bytes: Data(text.utf8))
            guard case .imported(let id) = try Importer(archive: archive).importMessage(raw) else { throw CocoaError(.fileWriteUnknown) }
            return id
        }
    }

    func fixture() throws -> Fixture {
        let f = try Fixture()
        for _ in 0..<3 { try f.add(from: "Accounts Team <accounts@shop.example>", account: f.work) }
        try f.add(from: "accounts@shop.example", account: f.work)
        for _ in 0..<2 { try f.add(from: "Alice Archer <alice@example.org>", account: f.home) }
        try f.add(from: "Bob Acton <bob@example.org>", account: f.work)
        try f.add(from: "carol@example.org", account: f.home)
        return f
    }

    @Test func oneLetterPrefixMatchesAddressNameAndWordsMostFrequentFirst() async throws {
        let f = try fixture()
        let found = try await f.searcher.senderSuggestions(prefix: "A", accounts: [], limit: 10)
        #expect(found.map(\.sender.address) == ["accounts@shop.example", "alice@example.org", "bob@example.org"])
        #expect(found.map(\.messageCount) == [4, 2, 1])
        // The display name it used most often labels the token.
        #expect(found.first?.sender.name == "Accounts Team")
    }

    @Test func fullAddressGivesThatSender() async throws {
        let f = try fixture()
        let found = try await f.searcher.senderSuggestions(prefix: "carol@example.org", accounts: [], limit: 10)
        #expect(found == [SenderSuggestion(sender: EmailAddress(name: nil, address: "carol@example.org"), messageCount: 1)])
    }

    @Test func accountsSpamLimitAndWildcards() async throws {
        let f = try fixture()
        #expect(try await f.searcher.senderSuggestions(prefix: "a", accounts: [f.home], limit: 10).map(\.sender.address)
            == ["alice@example.org"])
        #expect(try await f.searcher.senderSuggestions(prefix: "a", accounts: [], limit: 1).count == 1)
        #expect(try await f.searcher.senderSuggestions(prefix: "  ", accounts: [], limit: 10).isEmpty)
        // A typed % or _ is a character, not a wildcard.
        #expect(try await f.searcher.senderSuggestions(prefix: "%", accounts: [], limit: 10).isEmpty)
        #expect(try await f.searcher.senderSuggestions(prefix: "_", accounts: [], limit: 10).isEmpty)

        // Spam is left out, as in search.
        try await f.archive.database.write { db in
            try db.execute(sql: """
                UPDATE messages SET source_state = 'spam' WHERE from_address_id = (SELECT id FROM addresses WHERE address = 'alice@example.org')
                """)
        }
        #expect(try await f.searcher.senderSuggestions(prefix: "al", accounts: [], limit: 10).isEmpty)
    }
}
