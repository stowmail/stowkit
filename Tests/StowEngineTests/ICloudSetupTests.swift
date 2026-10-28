import CryptoKit
import Foundation
import GRDB
import StowCore
import StowEngine
import StowSecrets
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

/// An iCloud-like server: INBOX and Archive with mail, Junk and Deleted
/// Messages with mail that must not be archived (D-104, D-469).
func icloudServer(_ fixtures: [(name: String, bytes: Data)]) -> FakeIMAPServer {
    let messages = fixtures.enumerated().map { index, fixture in
        FakeIMAPServer.Message(uid: UInt32(index + 1), bytes: fixture.bytes, flags: index == 0 ? ["\\Seen"] : [])
    }
    let half = messages.count / 2
    let server = FakeIMAPServer(mailboxes: [
        .init(name: "INBOX", attributes: [], uidValidity: 21, messages: Array(messages.prefix(half))),
        .init(name: "Archive", attributes: ["\\Archive"], uidValidity: 22, messages: Array(messages.dropFirst(half))),
        .init(name: "Sent Messages", attributes: ["\\Sent"], uidValidity: 23, messages: []),
        .init(name: "Junk", attributes: ["\\Junk"], uidValidity: 24, messages: Array(messages.prefix(1))),
        .init(name: "Deleted Messages", attributes: ["\\Trash"], uidValidity: 25, messages: Array(messages.prefix(1))),
    ])
    server.capabilities = ["IMAP4rev1", "AUTH=PLAIN", "SASL-IR", "UIDPLUS"]
    server.examineAnswersReadWrite = true // as iCloud does (D-474)
    server.acceptedPasswords = ["sam@icloud.example abcd-efgh-ijkl-mnop"]
    return server
}

@Suite(.serialized) struct ICloudSetupTests {
    let keychain = KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
    let good = try! AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop")
    let wrong = try! AppSpecificPassword(typed: "zzzz-zzzz-zzzz-zzzz")

    func setUp(_ fixtures: [(name: String, bytes: Data)] = []) async throws -> (Archive, ArchiveAccounts, PasswordStore, FakeIMAPServer, IMAPEndpoint, URL) {
        let root = TestFixtures.temporaryDirectory()
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        let server = icloudServer(fixtures)
        let port = try await server.start()
        return (archive, ArchiveAccounts(archive: archive), PasswordStore(keychain: keychain), server,
                .plaintextLoopbackAcceptingPasswordsForTests(port: Int(port)), root)
    }

    /// QA: `account add icloud` stores the password only after the server accepts it.
    @Test func addStoresOnlyAfterTheServerAccepts() async throws {
        defer { try? keychain.deleteAll() }
        let (_, accounts, passwords, server, endpoint, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }

        await #expect(throws: ICloudSetup.SetupError.passwordRefused) {
            _ = try await ICloudSetup.add(email: "sam@icloud.example", name: nil, password: wrong, accounts: accounts, passwords: passwords, endpoint: endpoint)
        }
        #expect(try accounts.all().isEmpty)
        #expect(try keychain.items().isEmpty)

        let outcome = try await ICloudSetup.add(email: " sam@icloud.example ", name: "Personal", password: good,
                                                accounts: accounts, passwords: passwords, endpoint: endpoint)
        guard case .added(let id) = outcome else { Issue.record("expected added"); return }
        let record = try #require(try accounts.record(id))
        #expect(record.account.provider == .icloud)
        #expect(record.account.email == "sam@icloud.example")
        #expect(record.account.displayName == "Personal")
        #expect(try passwords.password(for: id)?.withBytes { $0 } == Array("abcd-efgh-ijkl-mnop".utf8))
        #expect(server.plainUsers == ["sam@icloud.example", "sam@icloud.example"])
        // Signed in, listed folders and logged out: nothing else.
        #expect(server.commandLog.map { $0.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
            .allSatisfy { ["AUTHENTICATE", "LIST", "LOGOUT"].contains($0) })

        await #expect(throws: ICloudSetup.SetupError.alreadyAdded(id)) {
            _ = try await ICloudSetup.add(email: "SAM@icloud.example", name: nil, password: good, accounts: accounts, passwords: passwords, endpoint: endpoint)
        }
        await #expect(throws: ICloudSetup.SetupError.notAnAddress) {
            _ = try await ICloudSetup.add(email: "sam", name: nil, password: good, accounts: accounts, passwords: passwords, endpoint: endpoint)
        }
    }

    /// An Apple Account can be made with any address; the one people sign in to
    /// Apple with is often Gmail or Outlook, which is never iCloud Mail. Caught
    /// before anything is sent, with the right next step.
    @Test func otherServicesAddressesAreRefusedBeforeSignIn() async throws {
        defer { try? keychain.deleteAll() }
        let (_, accounts, passwords, server, endpoint, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let cases: [(String, ICloudSetup.OtherService)] = [
            ("sam@gmail.com", .gmail), ("Sam@GoogleMail.com", .gmail), ("sam@hotmail.co.uk", .outlook),
            ("sam@outlook.fr", .outlook), ("sam@live.com", .outlook), ("sam@yahoo.de", .yahoo),
            ("sam@aol.com", .aol), ("sam@proton.me", .proton),
        ]
        for (address, service) in cases {
            await #expect(throws: ICloudSetup.SetupError.notICloud(service), "\(address)") {
                _ = try await ICloudSetup.add(email: address, name: nil, password: good, accounts: accounts, passwords: passwords, endpoint: endpoint)
            }
        }
        #expect(server.connectionCount == 0)
        #expect(try accounts.all().isEmpty)
        #expect(ICloudSetup.SetupError.notICloud(.gmail).description.hasPrefix("That is a Gmail address, not iCloud Mail. To archive it, run `stowmail account add gmail`."))
        #expect(ICloudSetup.SetupError.notICloud(.outlook).description.hasPrefix("That is an Outlook address"))

        // iCloud addresses and custom domains (iCloud+) pass.
        for address in ["sam@icloud.com", "sam@me.com", "sam@mac.com", "sam@smithfamily.co.uk", " sam@livewire.org "] {
            #expect(throws: Never.self, "\(address)") { _ = try ICloudSetup.checkAddress(address) }
        }
    }

    /// Security: `account signin` replaces the password only after the new one is accepted.
    @Test func replaceOnlyAfterTheNewPasswordIsAccepted() async throws {
        defer { try? keychain.deleteAll() }
        let (_, accounts, passwords, server, endpoint, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        guard case .added(let id) = try await ICloudSetup.add(email: "sam@icloud.example", name: nil, password: good, accounts: accounts,
                                                              passwords: passwords, endpoint: endpoint) else { return }
        try accounts.setNeedsSignIn(id, true)
        let record = try #require(try accounts.record(id))

        await #expect(throws: ICloudSetup.SetupError.passwordRefused) {
            try await ICloudSetup.replacePassword(of: record, with: wrong, accounts: accounts, passwords: passwords, endpoint: endpoint)
        }
        #expect(try passwords.password(for: id)?.withBytes { $0 } == Array("abcd-efgh-ijkl-mnop".utf8))
        #expect(try accounts.record(id)?.needsSignIn == true)

        let replacement = try AppSpecificPassword(typed: "wxyz-wxyz-wxyz-wxyz")
        server.acceptedPasswords = ["sam@icloud.example wxyz-wxyz-wxyz-wxyz"]
        try await ICloudSetup.replacePassword(of: record, with: replacement, accounts: accounts, passwords: passwords, endpoint: endpoint)
        #expect(try passwords.password(for: id)?.withBytes { $0 } == Array("wxyz-wxyz-wxyz-wxyz".utf8))
        #expect(try accounts.record(id)?.needsSignIn == false)
    }

    @Test func removedAccountIsReconnectedWithItsID() async throws {
        defer { try? keychain.deleteAll() }
        let (_, accounts, passwords, server, endpoint, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        guard case .added(let id) = try await ICloudSetup.add(email: "sam@icloud.example", name: nil, password: good, accounts: accounts,
                                                              passwords: passwords, endpoint: endpoint) else { return }
        try passwords.delete(for: id)
        try accounts.disconnect(id)
        let outcome = try await ICloudSetup.add(email: "sam@icloud.example", name: nil, password: good, accounts: accounts, passwords: passwords, endpoint: endpoint)
        #expect(outcome == .reconnected(id))
        #expect(try accounts.record(id)?.isConnected == true)
        #expect(try passwords.hasPassword(for: id))
    }

    /// Step 1: `icloud` round-trips through the archive's accounts table, and a
    /// provider this build does not know is still left out (D-025).
    @Test func providerRoundTripsAndUnknownIsLeftOut() async throws {
        let (archive, accounts, _, server, _, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let account = Account(id: .generate(), provider: .icloud, email: "sam@icloud.example", displayName: "Sam")
        try accounts.add(AccountRecord(account: account))
        try await archive.database.write { db in
            try db.execute(sql: "INSERT INTO accounts (id, provider, email, display_name, created_at, needs_reauth) VALUES ('later', 'fastmail', 'x@example.com', 'X', 0, 0)")
        }
        #expect(try accounts.all().map(\.account) == [account])
        #expect(try await archive.database.read { try String.fetchOne($0, sql: "SELECT provider FROM accounts WHERE id = ?", arguments: [account.id.rawValue]) } == "icloud")
        #expect(RetentionGuide.kind(provider: .icloud, email: "sam@me.com") == .icloud)
        #expect(Provider.icloud.oauth == nil && Provider.icloud.credentialKind == .appSpecificPassword)
        #expect(Provider.gmail.oauth == .gmail && Provider.microsoft.oauth == .microsoft)
    }

    /// The whole path the CLI and the app use: `EngineSync` with the real
    /// `SessionFactory` and `TokenProvider`, signing in with the stored password.
    @Test func icloudSyncsEveryKeptFolderByteForByteReadOnly() async throws {
        defer { try? keychain.deleteAll() }
        let fixtures = try TestFixtures.small()
        let (archive, accounts, passwords, server, endpoint, root) = try await setUp(fixtures)
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        guard case .added(let id) = try await ICloudSetup.add(email: "sam@icloud.example", name: nil, password: good, accounts: accounts,
                                                              passwords: passwords, endpoint: endpoint) else { return }
        let account = try #require(try accounts.record(id)).account
        let tokens = TokenProvider(tokenStore: TokenStore(keychain: keychain), passwordStore: passwords, registry: accounts) { _ in
            throw OAuthError.noRefreshToken
        }
        let sync = EngineSync(archive: archive, settingsURL: root.appendingPathComponent("no-rules.json"), sleep: { _ in }) { account in
            let factory = SessionFactory(account: account, endpoint: endpoint, tokens: tokens, timeouts: IMAPTimeouts(connect: 5, read: 5))
            return { try await factory.open() }
        }
        _ = try await sync.syncer(for: account).run(SyncOptions(checkChanges: .full))

        let stored = try await archive.database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }
            .map { try archive.rawMessage($0)! }
        #expect(Set(stored) == Set(fixtures.map(\.bytes)))
        #expect(stored.count == fixtures.count)
        let skipped = try await archive.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM folders WHERE account_id = ? AND skipped_reason IS NOT NULL ORDER BY name", arguments: [id.rawValue])
        }
        #expect(skipped == ["Deleted Messages", "Junk"])
        #expect(server.commandLog.allSatisfy { !$0.contains("EXAMINE \"Junk\"") && !$0.contains("EXAMINE \"Deleted Messages\"") })
        #expect(server.commandLog.allSatisfy { !$0.uppercased().contains("SELECT ") && !$0.uppercased().contains("STORE") && !$0.contains("BODY[]") })
        #expect(server.commandLog.contains { $0.contains("BODY.PEEK[]") })
        #expect(server.mailboxes[0].messages.first?.flags == ["\\Seen"])
    }

    @Test func icloudRetentionStepsUseMailOnTheMac() {
        let before = Date(timeIntervalSince1970: 1_760_313_600) // 13 October 2025, 00:00 UTC
        let steps = RetentionGuide.guide(.icloud, before: before)
        #expect(steps.count == 5)
        #expect(steps.compactMap(\.search) == ["13 October 2025"])
        #expect(steps[0].text.contains("Mail on your Mac"))
        #expect(steps[2].text.contains("Include messages from Sent")) // off by default in Mail (28 Oct 2026)
        #expect(steps[4].text.contains("Trash"))
    }
}
