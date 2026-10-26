import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// R11: where a message is at the provider now, and when Stow stored it (UI-24).
@Suite(.serialized) struct MessagePlacesTests {
    @Test func placesFollowTheProviderAndImportedAtIsSet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-places-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        let account = AccountID(rawValue: "00000000-0000-4000-8000-0000000000dd")
        try archive.register(Account(id: account, provider: .gmail, email: "sam@example.com", displayName: "S"))
        let store = ArchiveSyncStore(archive: archive)
        _ = try await store.beginFolder(account, folder: "[Gmail]/All Mail", uidValidity: 1, exists: 1)
        let text = "From: a@example.org\r\nSubject: Quince\r\nMessage-ID: <q@example.org>\r\n\r\nquince\r\n"
        let before = Date()
        try await store.write(RawMessage(key: RawMessageKey(accountID: account, folder: "[Gmail]/All Mail", uidValidity: 1, uid: 1),
                                         labels: ["\\Inbox", "Receipts"], internalDate: Date(), size: text.utf8.count,
                                         bytes: Data(text.utf8)))
        let id = try #require(try await archive.database.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM messages") })
        let reader = MessageReader(archive: archive)
        var detail = try #require(try await reader.message(id, bodyLimit: 10))
        #expect(Set(detail.places.map(\.name)) == ["[Gmail]/All Mail", "\\Inbox", "Receipts"])
        #expect(detail.places.filter { $0.kind == .label }.count == 2)
        #expect(detail.places.allSatisfy { $0.accountID == account })
        let imported = try #require(detail.importedAt)
        #expect(imported.timeIntervalSince(before) > -2 && imported.timeIntervalSinceNow < 2)

        // Deleted at the provider: no places left, the archive keeps it.
        // Only the All Mail copy is marked; the label rows are left as they were, and still do not count.
        _ = try await store.markRemovedFromServer(account, folder: "[Gmail]/All Mail", uidValidity: 1, uids: [1], at: Date())
        try await store.setSourceStates(account, [id: .gone], at: Date(timeIntervalSince1970: 1_790_000_000))
        detail = try #require(try await reader.message(id, bodyLimit: 10))
        #expect(detail.places.isEmpty)
        #expect(detail.sourceState == .gone && detail.sourceStateAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func aDetailEncodedBeforeR11StillDecodes() throws {
        let old = """
            {"messageID":7,"accountID":"a","date":0,"to":[],"cc":[],"sourceState":"present","bodyFromHTML":false,
             "bodyLength":0,"bodyTruncated":false,"attachments":[]}
            """
        let detail = try JSONDecoder().decode(MessageDetail.self, from: Data(old.utf8))
        #expect(detail.places.isEmpty && detail.importedAt == nil && detail.sourceStateAt == nil)
        let round = try JSONDecoder().decode(MessageDetail.self, from: JSONEncoder().encode(detail))
        #expect(round == detail)
    }
}
