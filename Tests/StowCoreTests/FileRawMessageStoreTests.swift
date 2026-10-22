import Foundation
import Testing
@testable import StowCore

@Suite struct FileRawMessageStoreTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stow-raw-\(UUID().uuidString)", isDirectory: true)
    }

    /// Everything below the store root, files and directories.
    func allFiles() -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
    }

    func message(uid: UInt32, folder: String = "[Gmail]/All Mail", body: String = "Hello") -> RawMessage {
        RawMessage(
            key: RawMessageKey(accountID: AccountID(rawValue: "acct-1"), folder: folder, uidValidity: 42, uid: uid),
            labels: ["\\Inbox", "Receipts"],
            gmailMessageID: 1_700_000_000_000 + UInt64(uid),
            gmailThreadID: 99,
            internalDate: Date(timeIntervalSince1970: 1_700_000_000.5),
            size: body.utf8.count,
            bytes: Data("Subject: test\r\n\r\n\(body)\r\n".utf8)
        )
    }

    @Test func roundTripsEveryField() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        let original = message(uid: 7)
        try await store.write(original)
        try await store.flush()

        #expect(try await store.listKeys() == [original.key])
        #expect(try await store.read(original.key) == original)
    }

    @Test func writeIsIdempotentByKey() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        try await store.write(message(uid: 1))
        try await store.write(message(uid: 1, body: "different"))
        try await store.write(message(uid: 2))

        let keys = try await store.listKeys()
        #expect(keys.map(\.uid) == [1, 2])
        // The first write wins; repeats are ignored.
        let first = try await store.read(keys[0])
        #expect(String(decoding: first.bytes, as: UTF8.self).contains("Hello"))
    }

    @Test func awkwardFolderNamesStayInsideRoot() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        let names = ["../../escape", "Boîte/Reçus", "a.b", "", "%41"]
        for (index, name) in names.enumerated() {
            try await store.write(message(uid: UInt32(index + 1), folder: name))
        }
        let folders = try await store.listKeys().map(\.folder)
        #expect(Set(folders) == Set(names))
        // Nothing was written outside the root.
        let parentContents = try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)
        #expect(!parentContents.contains("escape"))
    }

    @Test func filesArePrivate() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        try await store.write(message(uid: 3))
        var checked = 0
        for url in allFiles() {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            #expect(permissions == (isDirectory ? 0o700 : 0o600), "\(url.lastPathComponent)")
            checked += 1
        }
        #expect(checked >= 5)
        let rootPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        #expect(rootPermissions?.intValue == 0o700)
    }

    @Test func incompleteMessagesAreNotListed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        try await store.write(message(uid: 1))
        // Simulate a crash after the .eml was written but before its metadata.
        let directory = try #require(allFiles().first { $0.pathExtension == "eml" }?.deletingLastPathComponent())
        try Data("partial".utf8).write(to: directory.appendingPathComponent("2.eml"))
        #expect(try await store.listKeys().map(\.uid) == [1])
    }

    @Test func readingAMissingKeyThrows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        await #expect(throws: FileRawMessageStoreError.self) {
            try await store.read(message(uid: 9).key)
        }
    }

    @Test func checkpointsRoundTrip() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        let account = AccountID(rawValue: "acct-1")
        #expect(try await store.checkpoint(accountID: account, folder: "INBOX") == nil)

        var checkpoint = SyncCheckpoint(accountID: account, folder: "INBOX", uidValidity: 5, highestUID: 100,
                                        updatedAt: Date(timeIntervalSince1970: 1_000))
        try await store.save(checkpoint)
        checkpoint.highestUID = 200
        try await store.save(checkpoint)

        #expect(try await store.checkpoint(accountID: account, folder: "INBOX") == checkpoint)
        // Checkpoint files are not mistaken for messages.
        #expect(try await store.listKeys().isEmpty)
    }
}
