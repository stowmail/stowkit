import CryptoKit
import Foundation
import GRDB
import StowCore
import StowEngine
import StowSecrets
import StowStore
@testable import StowSync
import StowTestSupport

/// A real archive in a temporary folder, synced by the real `AccountSyncer`
/// through `EngineSync` from a fake IMAP server.
final class EngineHarness: @unchecked Sendable {
    let root: URL
    let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
    let archive: Archive
    let server: FakeIMAPServer
    let port: UInt16
    let account: Account
    let sleeps = RecordedSleeps()

    init(server: FakeIMAPServer, provider: Provider = .microsoft, email: String = "sam@example.com") async throws {
        root = TestFixtures.temporaryDirectory()
        archive = try Archive.open(ArchiveLocation(root: root), keys: keys)
        self.server = server
        port = try await server.start()
        account = Account(id: .generate(), provider: provider, email: email, displayName: "Sam")
        try ArchiveAccounts(archive: archive).add(AccountRecord(account: account))
    }

    var sync: EngineSync {
        let port = Int(self.port)
        let sleeps = self.sleeps
        return EngineSync(archive: archive, settingsURL: root.appendingPathComponent("no-rules.json"),
                          sleep: { try await sleeps.sleep($0) }) { account in
            {
                let session = try await IMAPSession.connect(to: .plaintextLoopback(port: port), timeouts: IMAPTimeouts(connect: 5, read: 5))
                try await session.authenticate(user: account.email, accessToken: "good-token")
                return session
            }
        }
    }

    func run(_ options: SyncOptions = SyncOptions(checkChanges: .full)) async throws -> SyncReport {
        try await sync.syncer(for: account).run(options)
    }

    func count(_ table: String, _ condition: String = "1") throws -> Int {
        try archive.database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE \(condition)")! }
    }

    /// Stored message bytes, by Message-ID.
    func storedBytes() throws -> [Data] {
        let ids = try archive.database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }
        return try ids.map { try archive.rawMessage($0)! }
    }

    func cleanUp() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

extension EngineHarness {
    /// A Gmail account's archive. Gmail syncs only through the Gmail API (D-583,
    /// D-601), which tests play with `FakeGmailAPI`; the IMAP server is never reached.
    static func gmail() async throws -> EngineHarness {
        try await EngineHarness(server: FakeIMAPServer(), provider: .gmail)
    }
}

let inbox = "INBOX"

/// A Microsoft-like server: INBOX with the fixtures (sparse UIDs, the first
/// one read), plus an empty Junk Email (`\Junk`, never synced) and Deleted
/// Items (`\Trash`, synced), as `FolderPlanner.planMicrosoft` expects.
/// Exchange Online does not offer CONDSTORE; `condstore` adds it for the tests
/// of that path, which is the same for every IMAP provider.
func microsoftServer(_ fixtures: [(name: String, bytes: Data)], uidValidity: UInt32 = 7, condstore: Bool = false) -> FakeIMAPServer {
    let messages = fixtures.enumerated().map { index, fixture in
        FakeIMAPServer.Message(uid: UInt32(index * 2 + 3), bytes: fixture.bytes, flags: index == 0 ? ["\\Seen"] : [])
    }
    let server = FakeIMAPServer(mailboxes: [
        .init(name: inbox, attributes: ["\\HasNoChildren"], uidValidity: uidValidity, messages: messages),
        .init(name: "Junk Email", attributes: ["\\HasNoChildren", "\\Junk"], uidValidity: 4, messages: []),
        .init(name: "Deleted Items", attributes: ["\\HasNoChildren", "\\Trash"], uidValidity: 5, messages: []),
    ])
    server.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR", "UIDPLUS"]
    if condstore { server.capabilities.append("CONDSTORE") }
    return server
}

extension FakeIMAPServer {
    func mutate(_ name: String, _ change: (inout Mailbox) -> Void) {
        var all = mailboxes
        let index = all.firstIndex { $0.name == name }!
        change(&all[index])
        mailboxes = all
    }

    func mailbox(_ name: String) -> Mailbox { mailboxes.first { $0.name == name }! }
}

/// Fails on a given write, as if the process were killed between two messages.
actor KillingSink: RawMessageSink {
    let inner: RawMessageSink
    let killOnWrite: Int
    private var writes = 0

    init(_ inner: RawMessageSink, killOnWrite: Int) {
        self.inner = inner
        self.killOnWrite = killOnWrite
    }

    func write(_ message: RawMessage) async throws {
        writes += 1
        if writes == killOnWrite { throw CocoaError(.fileWriteUnknown) }
        try await inner.write(message)
    }

    func flush() async throws { try await inner.flush() }
}
