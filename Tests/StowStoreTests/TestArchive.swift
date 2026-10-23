import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
@testable import StowStore

/// A throwaway archive in a temporary folder, with random keys that never touch the Keychain.
struct TestArchive {
    let location: ArchiveLocation
    let keys: ArchiveKeys
    let archive: Archive
    let account = Account(id: AccountID(rawValue: "00000000-0000-4000-8000-000000000001"), provider: .microsoft,
                          email: "sam@example.com", displayName: "Test")

    init(keys: ArchiveKeys = TestArchive.randomKeys()) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stow-test-\(UUID().uuidString)", isDirectory: true)
        location = ArchiveLocation(root: root)
        self.keys = keys
        archive = try Archive.open(location, keys: keys)
        try archive.register(account)
    }

    static func randomKeys() -> ArchiveKeys {
        ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
    }

    func remove() {
        try? FileManager.default.removeItem(at: location.root)
    }

    /// A fixture as the sync side would deliver it.
    func raw(_ data: Data, folder: String = "INBOX", uid: UInt32, labels: [String] = []) -> RawMessage {
        RawMessage(key: RawMessageKey(accountID: account.id, folder: folder, uidValidity: 1, uid: uid),
                   labels: labels, internalDate: Date(timeIntervalSince1970: 1_757_000_000 + Double(uid) * 60),
                   size: data.count, bytes: data)
    }

    /// Every fixture, in file order, as raw messages in INBOX.
    func fixtureMessages() throws -> [RawMessage] {
        try Fixtures.allFiles().enumerated().map { index, file in
            raw(try Data(contentsOf: Fixtures.directory.appendingPathComponent(file)), uid: UInt32(index + 1))
        }
    }

    func count(_ table: String, _ condition: String = "1") throws -> Int {
        try archive.database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE \(condition)")! }
    }

    func files(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
    }
}

/// An in-memory `RawMessageSource`.
struct MemorySource: RawMessageSource {
    let messages: [RawMessageKey: RawMessage]

    init(_ messages: [RawMessage]) {
        self.messages = Dictionary(messages.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func listKeys() async throws -> [RawMessageKey] { messages.keys.sorted() }

    func read(_ key: RawMessageKey) async throws -> RawMessage {
        guard let message = messages[key] else { throw CocoaError(.fileNoSuchFile) }
        return message
    }
}
