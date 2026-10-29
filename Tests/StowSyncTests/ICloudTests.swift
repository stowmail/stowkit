import Foundation
import StowCore
import StowSecrets
import StowTestSupport
import Testing
@testable import StowSync

/// A sentinel password: if any part of this shows up in a log line or a
/// description, the test fails. Synthetic, never a real password.
let sentinelTyped = "Qzxw-Vqzk-Jqxz-Wvkq"
let sentinelLetters = "QzxwVqzkJqxzWvkq"

/// An iCloud-like mailbox. `flags` sends every SPECIAL-USE flag; without it,
/// what iCloud sent on 28 Oct 2026: `\Sent` and `\Trash` only. Like iCloud,
/// it answers EXAMINE with `[READ-WRITE]` (D-474).
func icloudServer(_ fixtures: [(name: String, bytes: Data)] = [], flags: Bool = true) -> FakeIMAPServer {
    let messages = fixtures.enumerated().map { index, fixture in
        FakeIMAPServer.Message(uid: UInt32(index + 1), bytes: fixture.bytes)
    }
    let server = FakeIMAPServer(mailboxes: [
        .init(name: "INBOX", attributes: [], uidValidity: 11, messages: messages),
        .init(name: "Sent Messages", attributes: ["\\Sent"], uidValidity: 12, messages: []),
        .init(name: "Drafts", attributes: flags ? ["\\Drafts"] : [], uidValidity: 13, messages: []),
        .init(name: "Deleted Messages", attributes: ["\\Trash"], uidValidity: 14, messages: []),
        .init(name: "Junk", attributes: flags ? ["\\Junk"] : [], uidValidity: 15, messages: []),
        .init(name: "Archive", attributes: flags ? ["\\Archive"] : [], uidValidity: 16, messages: []),
    ])
    server.capabilities = ["IMAP4rev1", "AUTH=PLAIN", "SASL-IR", "UIDPLUS"]
    server.examineAnswersReadWrite = true
    return server
}

@Suite struct AppSpecificPasswordTests {
    @Test func acceptsApplesShapeAndTidiesSeparators() throws {
        for typed in ["abcd-efgh-ijkl-mnop", "abcdefghijklmnop", " abcd efgh ijkl mnop ", "abcd - efgh - ijkl - mnop"] {
            let password = try AppSpecificPassword(typed: typed)
            #expect(password.withBytes { String(decoding: $0, as: UTF8.self) } == "abcd-efgh-ijkl-mnop", "\(typed)")
        }
    }

    @Test func refusesAnythingElse() {
        #expect(throws: AppSpecificPassword.ShapeError.empty) { try AppSpecificPassword(typed: "  - ") }
        for typed in ["abcd-efgh-ijkl-mno", "abcd-efgh-ijkl-mnopq", "abcd-efgh-ijkl-mn0p", "MyAppleP@ssw0rd!", "abcd_efgh_ijkl_mnop", "ábcd-efgh-ijkl-mnop"] {
            #expect(throws: AppSpecificPassword.ShapeError.wrongShape, "\(typed)") { try AppSpecificPassword(typed: typed) }
        }
    }

    @Test func describesItselfAsRedactedEverywhere() throws {
        let password = try AppSpecificPassword(typed: sentinelTyped)
        let command = ReadOnlyCommand.authenticatePlain(user: "sam@example.com", password: password, initialResponse: true)
        var dumped = ""
        dump(command, to: &dumped)
        dump(password, to: &dumped)
        let texts = [
            "\(password)", String(describing: password), String(reflecting: password), password.debugDescription,
            "\(command)", String(reflecting: command), command.verb, dumped,
            "\(SignInCredential.password(password))", String(reflecting: SignInCredential.password(password)),
        ]
        for text in texts {
            #expect(!text.lowercased().contains("qzxw"), "\(text)")
            #expect(!text.contains("16"), "length shown: \(text)")
        }
    }

    @Test func saslPlainIsRFC4616() throws {
        let bytes = SASLPlain.response(user: "sam@example.com", password: try AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop"))
        #expect(bytes == [0] + Array("sam@example.com".utf8) + [0] + Array("abcd-efgh-ijkl-mnop".utf8))
    }

    @Test func storedWithTheTokensAttributesAndDeleted() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let store = PasswordStore(keychain: keychain)
        let id = AccountID.generate()
        #expect(try store.password(for: id) == nil)
        #expect(try store.hasPassword(for: id) == false)
        try store.save(try AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop"), for: id)
        #expect(try store.hasPassword(for: id))
        #expect(try store.password(for: id)?.withBytes { $0 } == Array("abcd-efgh-ijkl-mnop".utf8))
        try store.save(try AppSpecificPassword(typed: "ponm-lkji-hgfe-dcba"), for: id)
        #expect(try store.password(for: id)?.withBytes { $0 } == Array("ponm-lkji-hgfe-dcba".utf8))
        try store.delete(for: id)
        #expect(try store.password(for: id) == nil)
        #expect(try keychain.items().isEmpty)
    }
}

@Suite struct ICloudFolderPlanTests {
    func folder(_ name: String, _ attributes: String...) -> IMAPFolder {
        IMAPFolder(name: name, rawName: Array(name.utf8), separator: "/", attributes: Set(attributes.map { $0.lowercased() }))
    }

    @Test func syncsEverythingButJunkAndDeletedMessages() throws {
        let folders = [folder("INBOX"), folder("Sent Messages", "\\Sent"), folder("Drafts", "\\Drafts"), folder("Deleted Messages", "\\Trash"),
                       folder("Junk", "\\Junk"), folder("Archive", "\\Archive"), folder("Notes"), folder("Projects", "\\Noselect"), folder("Projects/2026")]
        let plan = try FolderPlanner.plan(provider: .icloud, folders: folders, capabilities: [])
        #expect(plan.toSync.map(\.name) == ["INBOX", "Sent Messages", "Drafts", "Archive", "Notes", "Projects/2026"])
        #expect(Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.folder.name, $0.reason) }) == [
            "Deleted Messages": "Deleted Messages: iCloud erases it after 30 days, not archived (D-104, D-469)",
            "Junk": "Junk: not archived (D-104)",
            "Projects": "cannot be opened (\\Noselect)",
        ])
    }

    @Test func fallsBackToNamesOnlyWithoutFlags() throws {
        let unflagged = try FolderPlanner.plan(provider: .icloud, folders: [folder("INBOX"), folder("Junk"), folder("Deleted Messages")], capabilities: [])
        #expect(unflagged.toSync.map(\.name) == ["INBOX"])
        // With flags present, a user folder that merely has the name is kept.
        let flagged = try FolderPlanner.plan(provider: .icloud, folders: [folder("Junk"), folder("Spam", "\\Junk"), folder("Bin", "\\Trash")], capabilities: [])
        #expect(flagged.toSync.map(\.name) == ["Junk"])
    }
}

// Debug only: these sign in over plain text through `IMAPEndpoint.plaintextLoopbackAcceptingPasswordsForTests`,
// which release builds do not have (D-471), so `swift test -c release` leaves them out.
#if DEBUG
@Suite(.serialized) struct ICloudSignInTests {
    let keychain = makeTestKeychain()

    func endpoint(_ port: UInt16) -> IMAPEndpoint { .plaintextLoopbackAcceptingPasswordsForTests(port: Int(port)) }

    @Test(arguments: [true, false]) func plainSignsInWithOrWithoutSASLIR(saslIR: Bool) async throws {
        let server = icloudServer()
        if !saslIR { server.capabilities.removeAll { $0 == "SASL-IR" } }
        server.acceptedPasswords = ["sam@icloud.example abcd-efgh-ijkl-mnop"]
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: endpoint(port))
        try await session.authenticate(user: "sam@icloud.example", password: try AppSpecificPassword(typed: "abcdefghijklmnop"))
        #expect(try await session.listFolders().count == 6)
        await session.logout()
        #expect(server.plainUsers == ["sam@icloud.example"])
        #expect(server.plainContinuations == (saslIR ? 0 : 1))
        #expect(server.commandLog.contains { $0.hasSuffix("AUTHENTICATE PLAIN [redacted]") })
        assertReadOnly(server.commandLog)
    }

    @Test func refusedPasswordIsAuthenticationFailed() async throws {
        let server = icloudServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: endpoint(port))
        await #expect(throws: SyncError.authenticationFailed("NO Authentication Failed")) {
            try await session.authenticate(user: "sam@icloud.example", password: try AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop"))
        }
        await session.disconnect()
    }

    /// Security checklist: AUTHENTICATE PLAIN cannot be sent without implicit TLS.
    /// The plain-text fake server must receive nothing at all.
    @Test func noPasswordOverPlainText() async throws {
        let server = icloudServer()
        server.acceptedPasswords = ["sam@icloud.example abcd-efgh-ijkl-mnop"]
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        await #expect(throws: SyncError.insecureConnection) {
            try await session.authenticate(user: "sam@icloud.example", password: try AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop"))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(server.bytesReceived == 0)
        #expect(server.plainUsers.isEmpty)

        // The connection itself refuses too, even if asked directly.
        let connection = try await IMAPConnection.connect(to: .plaintextLoopback(port: Int(port)), timeouts: .default)
        await #expect(throws: SyncError.insecureConnection) {
            try await connection.send(tag: "X1", .authenticatePlain(user: "u", password: try AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop"), initialResponse: true))
        }
        await #expect(throws: SyncError.insecureConnection) {
            try await connection.sendPlainResponse(user: "u", password: try AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop"))
        }
        await connection.close()
        await session.disconnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(server.bytesReceived == 0)
    }

    /// A TLS handshake that fails is its own error, never retried as a network
    /// fault and never skipped. The plain-text fake server cannot complete one.
    @Test func failedTLSHandshakeIsCertificateRejected() async throws {
        let server = icloudServer()
        server.acceptedPasswords = ["sam@icloud.example abcd-efgh-ijkl-mnop"]
        let port = try await server.start()
        defer { server.stop() }
        do {
            _ = try await IMAPSession.connect(to: IMAPEndpoint(host: "127.0.0.1", port: Int(port)))
            Issue.record("expected the TLS handshake to fail")
        } catch let error as SyncError {
            guard case .certificateRejected = error else {
                Issue.record("expected certificateRejected, got \(error)")
                return
            }
            #expect(!error.isRetryable)
            #expect(error.description.contains("never skips this check"))
        }
        #expect(server.plainUsers.isEmpty)
    }

    func setUp(_ server: FakeIMAPServer, password: String = "abcd-efgh-ijkl-mnop") async throws -> (AccountRegistry, TokenProvider, Account, SessionFactory) {
        let port = try await server.start()
        let registry = AccountRegistry(keychain: keychain)
        let account = Account(id: .generate(), provider: .icloud, email: "sam@icloud.example", displayName: "Sam")
        try registry.add(AccountRecord(account: account))
        try PasswordStore(keychain: keychain).save(try AppSpecificPassword(typed: password), for: account.id)
        let tokens = TokenProvider(tokenStore: TokenStore(keychain: keychain), registry: registry) { _ in
            Issue.record("iCloud must never ask for an OAuth client")
            throw OAuthError.noRefreshToken
        }
        let factory = SessionFactory(account: account, endpoint: endpoint(port), tokens: tokens, timeouts: IMAPTimeouts(connect: 5, read: 5))
        return (registry, tokens, account, factory)
    }

    @Test func sessionFactorySignsInWithTheStoredPassword() async throws {
        defer { try? keychain.deleteAll() }
        let server = icloudServer()
        server.acceptedPasswords = ["sam@icloud.example abcd-efgh-ijkl-mnop"]
        defer { server.stop() }
        let (_, _, _, factory) = try await setUp(server)
        let session = try await factory.open()
        #expect(try await session.listFolders().count == 6)
        await session.logout()
    }

    /// QA: a revoked password gives the right message, marks the account and is not retried.
    @Test func refusedPasswordMarksTheAccountAndIsNeverRetried() async throws {
        defer { try? keychain.deleteAll() }
        let server = icloudServer()
        server.acceptedPasswords = ["sam@icloud.example ponm-lkji-hgfe-dcba"]
        defer { server.stop() }
        let (registry, _, account, factory) = try await setUp(server)
        await #expect(throws: SyncError.passwordRefused(account.id)) { _ = try await factory.open() }
        #expect(server.connectionCount == 1) // one try, no second sign-in
        #expect(try registry.record(account.id)?.needsSignIn == true)
        #expect(SyncError.passwordRefused(account.id).description.contains("revoked"))
        #expect(SyncError.passwordRefused(account.id).isRetryable == false)

        // Later opens fail at once, without connecting.
        await #expect(throws: SyncError.needsSignIn(account.id)) { _ = try await factory.open() }
        #expect(server.connectionCount == 1)
    }

    /// A network fault never marks the account.
    @Test func unreachableServerDoesNotMarkTheAccount() async throws {
        defer { try? keychain.deleteAll() }
        let server = icloudServer()
        let (registry, _, account, factory) = try await setUp(server)
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        do {
            _ = try await factory.open()
            Issue.record("expected a connection failure")
        } catch let error as SyncError {
            #expect(error.isRetryable, "\(error)")
        }
        #expect(try registry.record(account.id)?.needsSignIn == false)
    }

    @Test func missingPasswordNeedsSignIn() async throws {
        defer { try? keychain.deleteAll() }
        let server = icloudServer()
        defer { server.stop() }
        let (registry, _, account, factory) = try await setUp(server)
        try PasswordStore(keychain: keychain).delete(for: account.id)
        await #expect(throws: SyncError.needsSignIn(account.id)) { _ = try await factory.open() }
        #expect(try registry.record(account.id)?.needsSignIn == true)
        #expect(server.connectionCount == 0)
    }

    /// D-474: an iCloud session accepts EXAMINE's `[READ-WRITE]`; any other
    /// session still refuses it, even through `SessionFactory`.
    @Test func onlyICloudSessionsAcceptAReadWriteExamine() async throws {
        defer { try? keychain.deleteAll() }
        let server = icloudServer()
        server.acceptedPasswords = ["sam@icloud.example abcd-efgh-ijkl-mnop"]
        defer { server.stop() }
        let (_, _, _, factory) = try await setUp(server)
        let inbox = IMAPFolder(name: "INBOX", rawName: Array("INBOX".utf8), separator: "/", attributes: [])
        let icloud = try await factory.open()
        #expect(try await icloud.examine(inbox, condstore: true).uidValidity == 11)
        await icloud.logout()

        let gmail = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(server.port)))
        try await gmail.authenticate(user: "sam@example.com", accessToken: "good-token")
        await #expect(throws: SyncError.protocolViolation("EXAMINE was not confirmed as read-only")) { _ = try await gmail.examine(inbox) }
        await gmail.disconnect()
        assertReadOnly(server.commandLog)
        #expect(!server.commandLog.contains { $0.uppercased().contains(" SELECT ") })
    }

    /// What iCloud actually sends (28 Oct 2026): `\Sent` and `\Trash` only,
    /// so Junk is found by name and Deleted Messages by its flag (D-469).
    @Test func folderPlanMatchesWhatICloudSends() throws {
        let server = icloudServer(flags: false)
        let folders = server.mailboxes.map { IMAPFolder(name: $0.name, rawName: Array($0.name.utf8), separator: "/", attributes: Set($0.attributes.map { $0.lowercased() })) }
        let plan = try FolderPlanner.plan(provider: .icloud, folders: folders, capabilities: [])
        #expect(Set(plan.toSync.map(\.name)) == ["INBOX", "Sent Messages", "Drafts", "Archive"])
    }

    @Test func tooManyConnectionsIsThrottled() {
        #expect(IMAPSession.classifyBye("Too many simultaneous connections") == .throttled("Too many simultaneous connections"))
    }
}
#endif

// Debug only: these sign in over plain text through `IMAPEndpoint.plaintextLoopbackAcceptingPasswordsForTests`,
// which release builds do not have (D-471), so `swift test -c release` leaves them out.
#if DEBUG
/// Security checklist: a sentinel password appears in no log line, error or
/// description, at any level (the capturing handler logs at trace).
@Suite(.serialized) struct ICloudSecretTests {
    @Test func sentinelPasswordAppearsNowhere() async throws {
        _ = CapturedLogs.installed
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let password = try AppSpecificPassword(typed: sentinelTyped)
        var errors: [String] = []

        for (accepted, saslIR) in [(true, true), (true, false), (false, true), (false, false)] {
            let server = icloudServer()
            if !saslIR { server.capabilities.removeAll { $0 == "SASL-IR" } }
            if accepted { server.acceptedPasswords = ["sam@icloud.example Qzxw-Vqzk-Jqxz-Wvkq"] }
            let port = try await server.start()
            let registry = AccountRegistry(keychain: keychain)
            let account = Account(id: .generate(), provider: .icloud, email: "sam@icloud.example", displayName: "Sam")
            try registry.add(AccountRecord(account: account))
            try PasswordStore(keychain: keychain).save(password, for: account.id)
            let tokens = TokenProvider(tokenStore: TokenStore(keychain: keychain), registry: registry) { _ in throw OAuthError.noRefreshToken }
            let factory = SessionFactory(account: account, endpoint: .plaintextLoopbackAcceptingPasswordsForTests(port: Int(port)), tokens: tokens)
            do {
                let session = try await factory.open()
                _ = try await session.listFolders()
                await session.logout()
            } catch {
                errors += ["\(error)", String(reflecting: error)]
            }
            for line in server.commandLog { errors.append(line) }
            server.stop()
            try keychain.deleteAll()
        }
        // Plain text: refused before sending.
        let server = icloudServer()
        let port = try await server.start()
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        do { try await session.authenticate(user: "sam@icloud.example", password: password) } catch { errors += ["\(error)", String(reflecting: error)] }
        await session.disconnect()
        server.stop()

        #expect(errors.count >= 6)
        let logs = CapturedLogs.shared.all
        #expect(logs.contains { $0.contains("AUTHENTICATE PLAIN") }) // the handler captured the sign-ins
        let plainBase64 = Data(SASLPlain.response(user: "sam@icloud.example", password: password)).base64EncodedString()
        for text in logs + errors {
            #expect(!text.lowercased().contains("qzxw"), "\(text)")
            #expect(!text.lowercased().contains(sentinelLetters.lowercased()), "\(text)")
            #expect(!text.contains(plainBase64), "\(text)")
        }
    }
}
#endif
