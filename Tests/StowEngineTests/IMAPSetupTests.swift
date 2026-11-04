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

@Suite struct IMAPSetupAddressTests {
    /// D-490 the other way round (brief step 5): an address with a provider of
    /// its own is sent to that provider's command before anything is asked.
    @Test func ownProvidersArePointedAtTheirOwnCommand() {
        let cases: [(String, IMAPSetup.OwnProvider)] = [
            ("sam@gmail.com", .gmail), ("sam@googlemail.com", .gmail), ("sam@outlook.com", .outlook), ("sam@hotmail.co.uk", .outlook),
            ("sam@icloud.com", .icloud), ("sam@me.com", .icloud), ("sam@mac.com", .icloud), ("sam@proton.me", .proton), ("sam@pm.me", .proton),
        ]
        for (address, provider) in cases {
            #expect(throws: IMAPSetup.SetupError.ownProvider(provider), "\(address)") { try IMAPSetup.checkAddress(address) }
        }
        #expect(IMAPSetup.SetupError.ownProvider(.gmail).description.contains("stowmail account add gmail"))
        #expect(IMAPSetup.SetupError.ownProvider(.icloud).description.contains("stowmail account add icloud"))
    }

    @Test func otherAddressesPass() throws {
        for address in ["sam@fastmail.com", "sam@yahoo.co.uk", "sam@gmx.de", " sam@example.net "] {
            #expect(try IMAPSetup.checkAddress(address) == address.trimmingCharacters(in: .whitespaces))
        }
        for bad in ["sam", "@example.net", "sam@example", "sam taylor@example.net"] {
            #expect(throws: IMAPSetup.SetupError.notAnAddress, "\(bad)") { try IMAPSetup.checkAddress(bad) }
        }
    }

    @Test func refusalNamesThePresetsAdviceOrTheGeneralCauses() throws {
        let fastmail = try #require(IMAPPreset.withID("fastmail"))
        let withAdvice = IMAPSetup.SetupError.passwordRefused(presetAdvice: fastmail.signInAdvice).description
        #expect(withAdvice.contains("app password") && withAdvice.hasSuffix("Nothing was saved."))
        let general = IMAPSetup.SetupError.passwordRefused(presetAdvice: nil).description
        #expect(general.contains("IMAP turned on") && general.contains("app password"))
    }
}

#if DEBUG
@Suite(.serialized) struct IMAPSetupCheckTests {
    func server(plain: Bool, optional: [String] = []) -> FakeIMAPServer {
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "INBOX", attributes: [], uidValidity: 31, messages: []),
            .init(name: "Sent", attributes: ["\\Sent"], uidValidity: 32, messages: []),
        ])
        server.capabilities = ["IMAP4rev1"] + (plain ? ["AUTH=PLAIN"] : []) + optional
        return server
    }

    @Test func checkSignsInListsAndReportsWhatIsMissing() async throws {
        let fake = server(plain: false, optional: ["UIDPLUS", "IDLE"])
        fake.acceptedPasswords = ["sam.taylor pw one"]
        let port = try await fake.start()
        defer { fake.stop() }
        let profile = try ServerProfile(host: "imap.example.net", username: "sam.taylor")
        let report = try await IMAPSetup.check(server: profile, password: try MailPassword(serverPassword: "pw one"),
                                               endpoint: .plaintextLoopbackAcceptingPasswordsForTests(port: Int(port)))
        #expect(report.folderCount == 2)
        #expect(report.capabilities.contains("UIDPLUS"))
        #expect(report.missingOptional == ["CONDSTORE", "SPECIAL-USE", "ENABLE", "LIST-EXTENDED"])
        #expect(fake.loginUsers == ["sam.taylor"])
        #expect(fake.commandLog.last?.hasSuffix("LOGOUT") == true)
    }

    @Test func refusedPasswordCarriesThePresetsAdvice() async throws {
        let fake = server(plain: true)
        let port = try await fake.start()
        defer { fake.stop() }
        let gmx = try #require(IMAPPreset.withID("gmx-de"))
        let profile = try ServerProfile(preset: gmx, username: "sam@gmx.de")
        await #expect(throws: IMAPSetup.SetupError.passwordRefused(presetAdvice: gmx.signInAdvice)) {
            _ = try await IMAPSetup.check(server: profile, password: try MailPassword(serverPassword: "wrong"),
                                          endpoint: .plaintextLoopbackAcceptingPasswordsForTests(port: Int(port)))
        }
        #expect(fake.plainUsers == ["sam@gmx.de"])
    }
}

/// `account add imap` and `account signin` (brief step 5, D-577): the account
/// and its server are stored together, and only after the server accepts the password.
@Suite(.serialized) struct IMAPAccountTests {
    let keychain = KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
    let good = try! MailPassword(serverPassword: "correct horse 7")
    let wrong = try! MailPassword(serverPassword: "wrong")

    func setUp() async throws -> (Archive, ArchiveAccounts, PasswordStore, FakeIMAPServer, IMAPEndpoint, URL) {
        let root = TestFixtures.temporaryDirectory()
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        let server = FakeIMAPServer(mailboxes: [
            .init(name: "INBOX", attributes: [], uidValidity: 41, messages: []),
            .init(name: "Spam", attributes: [], uidValidity: 42, messages: []),
        ])
        server.capabilities = ["IMAP4rev1", "AUTH=PLAIN", "UIDPLUS"]
        server.acceptedPasswords = ["sam.taylor correct horse 7"]
        let port = try await server.start()
        return (archive, ArchiveAccounts(archive: archive), PasswordStore(keychain: keychain), server,
                .plaintextLoopbackAcceptingPasswordsForTests(port: Int(port)), root)
    }

    func storedServer(_ archive: Archive, _ id: AccountID) throws -> AccountServer? {
        try ArchiveServers(archive: archive).server(for: id)
    }

    @Test func addStoresTheAccountAndItsServerOnlyAfterTheServerAccepts() async throws {
        defer { try? keychain.deleteAll() }
        let (archive, accounts, passwords, server, endpoint, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let profile = try ServerProfile(host: "IMAP.Example.NET.", port: 10993, username: "sam.taylor")

        await #expect(throws: IMAPSetup.SetupError.passwordRefused(presetAdvice: nil)) {
            _ = try await IMAPSetup.add(email: "sam@example.net", server: profile, name: nil, password: wrong,
                                        accounts: accounts, passwords: passwords, endpoint: endpoint)
        }
        #expect(try accounts.all().isEmpty)
        #expect(try keychain.items().isEmpty)
        #expect(try await archive.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM account_servers") } == 0)

        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let outcome = try await IMAPSetup.add(email: " sam@example.net ", server: profile, name: "Work", password: good,
                                              accounts: accounts, passwords: passwords, endpoint: endpoint, now: now)
        guard case .added(let id, let report) = outcome else { Issue.record("expected added"); return }
        #expect(report.folderCount == 2)
        let record = try #require(try accounts.record(id))
        #expect(record.account.provider == .imap && record.account.email == "sam@example.net" && record.account.displayName == "Work")
        #expect(try storedServer(archive, id) == AccountServer(
            host: "imap.example.net", port: 10993, security: "tls", username: "sam.taylor", preset: nil,
            capabilities: ["AUTH=PLAIN", "IMAP4REV1", "UIDPLUS"], capabilitiesAt: now))
        #expect(try passwords.password(for: id)?.withBytes { $0 } == Array("correct horse 7".utf8))
        #expect(server.plainUsers == ["sam.taylor", "sam.taylor"])

        // What sync reads back: the stored server, checked again.
        #expect(try ServerProfile.forAccount(record.account, in: archive) == profile)
        #expect(try ProviderProfile.forAccount(record.account, in: archive).endpoint == IMAPEndpoint(host: "imap.example.net", port: 10993))

        await #expect(throws: IMAPSetup.SetupError.alreadyAdded(id)) {
            _ = try await IMAPSetup.add(email: "SAM@example.net", server: profile, name: nil, password: good,
                                        accounts: accounts, passwords: passwords, endpoint: endpoint)
        }
    }

    @Test func signInAgainReplacesOnlyAfterAcceptanceAndRefreshesCapabilities() async throws {
        defer { try? keychain.deleteAll() }
        let (archive, accounts, passwords, server, endpoint, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let profile = try ServerProfile(host: "imap.example.net", username: "sam.taylor")
        guard case .added(let id, _) = try await IMAPSetup.add(email: "sam@example.net", server: profile, name: nil, password: good,
                                                               accounts: accounts, passwords: passwords, endpoint: endpoint) else { return }
        try accounts.setNeedsSignIn(id, true)
        let record = try #require(try accounts.record(id))

        await #expect(throws: IMAPSetup.SetupError.passwordRefused(presetAdvice: nil)) {
            try await IMAPSetup.replacePassword(of: record, with: wrong, accounts: accounts, passwords: passwords, endpoint: endpoint)
        }
        #expect(try passwords.password(for: id)?.withBytes { $0 } == Array("correct horse 7".utf8))
        #expect(try accounts.record(id)?.needsSignIn == true)

        server.acceptedPasswords = ["sam.taylor new one"]
        server.capabilities = ["IMAP4rev1", "AUTH=PLAIN", "UIDPLUS", "IDLE"]
        let later = Date(timeIntervalSince1970: 1_763_000_000)
        try await IMAPSetup.replacePassword(of: record, with: try MailPassword(serverPassword: "new one"), accounts: accounts,
                                            passwords: passwords, endpoint: endpoint, now: later)
        #expect(try passwords.password(for: id)?.withBytes { $0 } == Array("new one".utf8))
        #expect(try accounts.record(id)?.needsSignIn == false)
        let stored = try #require(try storedServer(archive, id))
        #expect(stored.capabilities?.contains("IDLE") == true && stored.capabilitiesAt == later)
    }

    /// D-032 and D-577: a removed account comes back with its ID only on the same server.
    @Test func reconnectsOnlyToTheSameServer() async throws {
        defer { try? keychain.deleteAll() }
        let (archive, accounts, passwords, server, endpoint, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let profile = try ServerProfile(host: "imap.example.net", username: "sam.taylor")
        guard case .added(let id, _) = try await IMAPSetup.add(email: "sam@example.net", server: profile, name: nil, password: good,
                                                               accounts: accounts, passwords: passwords, endpoint: endpoint) else { return }
        try passwords.delete(for: id)
        try accounts.disconnect(id)
        #expect(try storedServer(archive, id)?.host == "imap.example.net", "a disconnected account keeps its server row")
        let connections = server.connectionCount

        for other in [try ServerProfile(host: "imap.elsewhere.net", username: "sam.taylor"),
                      try ServerProfile(host: "imap.example.net", port: 10993, username: "sam.taylor"),
                      try ServerProfile(host: "imap.example.net", username: "sam@example.net")] {
            await #expect(throws: IMAPSetup.SetupError.differentServer(id)) {
                _ = try await IMAPSetup.add(email: "sam@example.net", server: other, name: nil, password: good,
                                            accounts: accounts, passwords: passwords, endpoint: endpoint)
            }
        }
        #expect(server.connectionCount == connections, "nothing is sent to a different server")
        #expect(try passwords.hasPassword(for: id) == false)

        let outcome = try await IMAPSetup.add(email: "sam@example.net", server: profile, name: nil, password: good,
                                              accounts: accounts, passwords: passwords, endpoint: endpoint)
        guard case .reconnected(let again, _) = outcome else { Issue.record("expected reconnected"); return }
        #expect(again == id)
        #expect(try accounts.record(id)?.isConnected == true)
        #expect(try passwords.hasPassword(for: id))
    }

    /// A row that would not pass the add-time checks never becomes a connection.
    @Test func aDamagedOrMissingServerRowIsServerDetailsMissing() async throws {
        let (archive, accounts, _, server, _, root) = try await setUp()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let account = Account(id: .generate(), provider: .imap, email: "sam@example.net", displayName: "Sam")
        try accounts.add(AccountRecord(account: account))
        #expect(throws: SyncError.serverDetailsMissing) { _ = try ServerProfile.forAccount(account, in: archive) }
        #expect(throws: SyncError.serverDetailsMissing) { _ = try ProviderProfile.forAccount(account, in: archive) }

        for (host, preset) in [("https://imap.example.net", nil), ("imap.example.net", "no-such-preset" as String?)] {
            try await archive.database.write { db in
                try db.execute(sql: "DELETE FROM account_servers")
                try db.execute(sql: "INSERT INTO account_servers (account_id, host, port, security, username, preset) VALUES (?, ?, 993, 'tls', 'sam', ?)",
                               arguments: [account.id.rawValue, host, preset])
            }
            #expect(throws: SyncError.serverDetailsMissing, "\(host) \(preset ?? "")") { _ = try ServerProfile.forAccount(account, in: archive) }
        }
        // Other providers have fixed servers and no row.
        let icloud = Account(id: .generate(), provider: .icloud, email: "sam@icloud.example", displayName: "Sam")
        #expect(try ServerProfile.forAccount(icloud, in: archive) == nil)
        #expect(try ProviderProfile.forAccount(icloud, in: archive) == .icloud)
    }
}
#endif
