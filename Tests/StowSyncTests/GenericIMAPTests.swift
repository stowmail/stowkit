import Foundation
import Network
import StowCore
import StowSecrets
import StowTestSupport
import Testing
@testable import StowSync

/// A sentinel server password, with a space, quotes and a non-ASCII letter so
/// LOGIN must send it as a literal. Synthetic, never a real password.
let serverSentinel = "Zq \"Wxv\" Ølkj 7731"

/// A server like a small self-hosted Dovecot: no Gmail extensions, its own
/// folder names, SPECIAL-USE on some folders only when `flags` is set.
func genericServer(_ messages: [FakeIMAPServer.Message] = [], flags: Bool = true, plain: Bool = true) -> FakeIMAPServer {
    let server = FakeIMAPServer(mailboxes: [
        .init(name: "INBOX", attributes: [], uidValidity: 21, messages: messages),
        .init(name: "Sent", attributes: flags ? ["\\Sent"] : [], uidValidity: 22, messages: []),
        .init(name: "Trash", attributes: flags ? ["\\Trash"] : [], uidValidity: 23, messages: []),
        .init(name: "Spam", attributes: flags ? ["\\Junk"] : [], uidValidity: 24, messages: []),
        .init(name: "Projects", attributes: ["\\Noselect"], uidValidity: 25, messages: []),
    ])
    server.capabilities = ["IMAP4rev1"] + (plain ? ["AUTH=PLAIN"] : [])
    return server
}

@Suite struct ServerProfileTests {
    @Test func hostsAreTidiedAndChecked() throws {
        #expect(try ServerProfile(host: " IMAP.Example.NET. ", username: "sam").host == "imap.example.net")
        #expect(try ServerProfile(host: "192.0.2.10", port: 10993, username: "sam").endpoint == IMAPEndpoint(host: "192.0.2.10", port: 10993))
        for bad in ["", "https://imap.example.net", "imap.example.net:993", "imap.example.net/mail", "sam@imap.example.net",
                    "imap example.net", "imäp.example.net", "-imap.example.net", "imap..example.net", "::1", String(repeating: "a", count: 64) + ".net"] {
            #expect(throws: ServerProfileError.badHost, "\(bad)") { try ServerProfile(host: bad, username: "sam") }
        }
        #expect(try ServerProfile(host: "xn--imp-qla.example.net", username: "sam").host == "xn--imp-qla.example.net")
    }

    @Test func portAndUsernameAreChecked() {
        #expect(throws: ServerProfileError.badPort) { try ServerProfile(host: "imap.example.net", port: 0, username: "sam") }
        #expect(throws: ServerProfileError.badPort) { try ServerProfile(host: "imap.example.net", port: 65536, username: "sam") }
        #expect(throws: ServerProfileError.badUsername) { try ServerProfile(host: "imap.example.net", username: "  ") }
        #expect(throws: ServerProfileError.badUsername) { try ServerProfile(host: "imap.example.net", username: "sam\r\nLOGOUT") }
        #expect(throws: ServerProfileError.unknownPreset("nope")) {
            try ServerProfile(host: "imap.example.net", port: 993, security: .tls, username: "sam", presetID: "nope")
        }
    }

    /// The username is stored as given, never assumed to be the address (brief step 1).
    @Test func usernameIsItsOwnField() throws {
        let server = try ServerProfile(host: "imap.example.net", username: "sam.taylor")
        #expect(server.username == "sam.taylor")
        #expect(server.security == .tls)
        #expect(server.presetID == nil)
    }

    @Test func presetsFixHostAndPortAndAreFoundByDomain() throws {
        let ids = IMAPPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for preset in IMAPPreset.all {
            #expect(preset.port == 993, "\(preset.id)")
            #expect(preset.maxConnections == 1, "\(preset.id): unmeasured presets stay at one connection")
            #expect(try ServerProfile.checkedHost(preset.host) == preset.host)
            let server = try ServerProfile(preset: preset, username: "sam@example.net")
            #expect(server.endpoint == IMAPEndpoint(host: preset.host, port: 993))
            #expect(server.preset == preset)
        }
        #expect(IMAPPreset.forDomain("fastmail.com")?.id == "fastmail")
        #expect(IMAPPreset.forDomain("yahoo.co.uk")?.id == "yahoo")
        #expect(IMAPPreset.forDomain("GMX.de")?.id == "gmx-de")
        #expect(IMAPPreset.forDomain("gmx.com")?.id == "gmx")
        #expect(IMAPPreset.forDomain("example.net") == nil)
        #expect(IMAPPreset.withID("FASTMAIL")?.host == "imap.fastmail.com")
    }

    @Test func imapProfileNeedsServerDetails() throws {
        #expect(throws: SyncError.serverDetailsMissing) { try ProviderProfile.forProvider(.imap) }
        let server = try ServerProfile(host: "imap.example.net", port: 10993, username: "sam")
        let profile = try ProviderProfile.forProvider(.imap, server: server)
        #expect(profile.provider == .imap)
        #expect(profile.endpoint == IMAPEndpoint(host: "imap.example.net", port: 10993))
        #expect(profile.maxConnections == 1) // brief step 4: one connection for an unknown server
        #expect(profile.dailyByteLimit == nil)
        #expect(Provider.imap.oauth == nil && Provider.imap.credentialKind == .password)
    }
}

@Suite struct MailPasswordTests {
    @Test func serverPasswordsAreKeptAsTyped() throws {
        let password = try MailPassword(serverPassword: " spaced out ")
        #expect(password.withBytes { String(decoding: $0, as: UTF8.self) } == " spaced out ")
        #expect(throws: MailPassword.ServerPasswordError.empty) { try MailPassword(serverPassword: "") }
        for bad in ["line\nbreak", "carriage\rreturn", "nul\u{0}byte"] {
            #expect(throws: MailPassword.ServerPasswordError.unsendable) { try MailPassword(serverPassword: bad) }
        }
        // Apple's shape check is for iCloud only.
        #expect(throws: MailPassword.ShapeError.wrongShape) { try MailPassword(typed: serverSentinel) }
    }

    @Test func loginDescribesItselfAsRedacted() throws {
        let password = try MailPassword(serverPassword: serverSentinel)
        let command = ReadOnlyCommand.login(user: "sam@example.net", password: password)
        var dumped = ""
        dump(command, to: &dumped)
        for text in ["\(password)", String(reflecting: password), "\(command)", String(reflecting: command), command.verb, dumped] {
            #expect(!text.contains("Wxv") && !text.contains("7731"), "\(text)")
        }
        #expect(command.verb == "LOGIN")
        #expect(command.carriesPassword)
    }
}

@Suite struct GenericFolderPlanTests {
    func folder(_ name: String, _ attributes: String...) -> IMAPFolder {
        IMAPFolder(name: name, rawName: Array(name.utf8), separator: ".", attributes: Set(attributes.map { $0.lowercased() }))
    }

    /// Junk is skipped; Trash is kept, since an unknown server may never empty it (D-571).
    @Test func skipsJunkByFlagAndKeepsTrash() throws {
        let plan = try FolderPlanner.plan(provider: .imap, folders: [
            folder("INBOX"), folder("Sent", "\\Sent"), folder("Trash", "\\Trash"), folder("Spam", "\\Junk"),
            folder("Junk"), folder("Lists", "\\Noselect"), folder("Lists.Swift"),
        ], capabilities: [])
        #expect(plan.toSync.map(\.name) == ["INBOX", "Sent", "Trash", "Junk", "Lists.Swift"])
        #expect(Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.folder.name, $0.reason) }) == [
            "Spam": "Junk: not archived (D-104)",
            "Lists": "cannot be opened (\\Noselect)",
        ])
    }

    @Test func fallsBackToCommonNamesWithoutFlags() throws {
        let plan = try FolderPlanner.plan(provider: .imap, folders: [
            folder("INBOX"), folder("INBOX.Spam"), folder("Spamverdacht"), folder("Bulk Mail"), folder("Papierkorb"), folder("Spam reports 2025"),
        ], capabilities: [])
        #expect(plan.toSync.map(\.name) == ["INBOX", "Papierkorb", "Spam reports 2025"])
    }
}

@Suite struct GenericIMAPConnectTests {
    /// Each connection failure has its own error (brief step 6), from the
    /// statuses measured on 3 Nov 2026 (`IMAPConnection.handshakeStatuses`).
    @Test func connectFailuresAreClassified() {
        func classify(_ error: Error) -> SyncError { IMAPConnection.classifyConnectFailure(error) }
        guard case .tlsHandshakeFailed = classify(NWError.tls(-9836)) else { Issue.record("plain text on a TLS port"); return }
        guard case .certificateRejected = classify(NWError.tls(-9808)) else { Issue.record("untrusted or wrong-name certificate"); return }
        guard case .certificateRejected = classify(NWError.tls(-9814)) else { Issue.record("expired certificate"); return }
        guard case .certificateRejected = classify(NWError.tls(-1)) else { Issue.record("an unknown TLS status stays a certificate refusal"); return }
        guard case .hostNotFound = classify(NWError.dns(-65554)) else { Issue.record("name lookup"); return }
        guard case .connectionRefused = classify(NWError.posix(.ECONNREFUSED)) else { Issue.record("refused"); return }
        #expect(classify(NWError.posix(.ETIMEDOUT)) == .timedOut)
        guard case .connectionFailed = classify(NWError.posix(.ENETUNREACH)) else { Issue.record("other network failure"); return }
        // Dovecot with PLAIN switched off refuses LOGIN this way; no password is wrong (D-575).
        #expect(IMAPSession.classifyAuthenticationFailure("NO Unsupported authentication mechanism.") == .noSupportedSignIn)
        #expect(IMAPSession.classifyAuthenticationFailure("NO [AUTHENTICATIONFAILED] Authentication failed.") == .authenticationFailed("NO [AUTHENTICATIONFAILED] Authentication failed."))
        #expect(!SyncError.certificateRejected("x").isRetryable)
        #expect(!SyncError.tlsHandshakeFailed("x").isRetryable)
        #expect(SyncError.hostNotFound("x").isRetryable && SyncError.connectionRefused("x").isRetryable)
    }

    /// Security checklist: "No credential is sent before TLS is up". A TLS
    /// connection to a plain-text server fails in the handshake, and the
    /// server receives no command at all, let alone a password.
    @Test func nothingIsSentToAServerThatDoesNotSpeakTLS() async throws {
        let server = genericServer()
        server.acceptedPasswords = ["sam \(serverSentinel)"]
        let port = try await server.start()
        defer { server.stop() }
        await #expect(throws: SyncError.self) {
            _ = try await IMAPSession.connect(to: IMAPEndpoint(host: "127.0.0.1", port: Int(port)))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(server.commandLog.isEmpty)
        #expect(server.plainUsers.isEmpty && server.loginUsers.isEmpty)
    }

    /// No LOGIN over plain text either, even when asked directly.
    @Test func noLoginOverPlainText() async throws {
        let server = genericServer(plain: false)
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        await #expect(throws: SyncError.insecureConnection) {
            try await session.authenticate(user: "sam", password: try MailPassword(serverPassword: serverSentinel), allowLogin: true)
        }
        let connection = try await IMAPConnection.connect(to: .plaintextLoopback(port: Int(port)), timeouts: .default)
        await #expect(throws: SyncError.insecureConnection) {
            try await connection.send(tag: "X1", .login(user: "sam", password: try MailPassword(serverPassword: serverSentinel)))
        }
        await connection.close()
        await session.disconnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(server.bytesReceived == 0)
    }
}

// Debug only: signs in over plain text through the loopback test endpoint (D-471).
#if DEBUG
@Suite(.serialized) struct GenericSignInTests {
    func endpoint(_ port: UInt16) -> IMAPEndpoint { .plaintextLoopbackAcceptingPasswordsForTests(port: Int(port)) }

    /// AUTH=PLAIN offered: PLAIN, never LOGIN (D-570 item 3).
    @Test func plainWhenOffered() async throws {
        let server = genericServer()
        server.capabilities.append("LOGIN-REFERRALS")
        server.acceptedPasswords = ["sam \(serverSentinel)"]
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: endpoint(port))
        try await session.authenticate(user: "sam", password: try MailPassword(serverPassword: serverSentinel), allowLogin: true)
        await session.logout()
        #expect(server.plainUsers == ["sam"])
        #expect(server.loginUsers.isEmpty)
    }

    /// No AUTH=PLAIN: LOGIN, with a password that needs a literal sent whole.
    @Test(arguments: [serverSentinel, "plain-ascii-password"]) func loginWhenPlainIsNotOffered(password: String) async throws {
        let server = genericServer(plain: false)
        server.acceptedPasswords = ["sam.taylor \(password)"]
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: endpoint(port))
        try await session.authenticate(user: "sam.taylor", password: try MailPassword(serverPassword: password), allowLogin: true)
        #expect(try await session.listFolders().count == 5)
        await session.logout()
        #expect(server.loginUsers == ["sam.taylor"])
        #expect(server.plainUsers.isEmpty)
        #expect(server.commandLog.contains { $0.hasSuffix("LOGIN [redacted]") })
        if password == serverSentinel { #expect(server.loginLiterals >= 1) }
        assertReadOnly(server.commandLog)
    }

    /// LOGINDISABLED and no AUTH=PLAIN: refused before any credential is sent.
    @Test func noSupportedSignInSendsNothing() async throws {
        let server = genericServer(plain: false)
        server.capabilities.append("LOGINDISABLED")
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: endpoint(port))
        await #expect(throws: SyncError.noSupportedSignIn) {
            try await session.authenticate(user: "sam", password: try MailPassword(serverPassword: serverSentinel), allowLogin: true)
        }
        await session.disconnect()
        #expect(server.plainUsers.isEmpty && server.loginUsers.isEmpty)
        #expect(!server.commandLog.contains { $0.contains("LOGIN") || $0.contains("AUTHENTICATE") })
    }

    /// iCloud never gets LOGIN (D-467): without `allowLogin`, PLAIN is sent even if not advertised.
    @Test func icloudPathNeverSendsLogin() async throws {
        let server = genericServer(plain: false)
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: endpoint(port))
        await #expect(throws: SyncError.self) {
            try await session.authenticate(user: "sam", password: try AppSpecificPassword(typed: "abcd-efgh-ijkl-mnop"))
        }
        await session.disconnect()
        #expect(server.loginUsers.isEmpty)
        #expect(server.plainUsers == ["sam"])
    }

    @Test func refusedLoginIsAuthenticationFailed() async throws {
        let server = genericServer(plain: false)
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: endpoint(port))
        await #expect(throws: SyncError.authenticationFailed("NO Authentication failed.")) {
            try await session.authenticate(user: "sam", password: try MailPassword(serverPassword: "wrong"), allowLogin: true)
        }
        await session.disconnect()
    }

    /// A generic server must answer EXAMINE `[READ-ONLY]`; D-474's exception is iCloud's alone (D-570 item 7).
    @Test func readWriteExamineIsRefused() async throws {
        let server = genericServer()
        server.examineAnswersReadWrite = true
        server.acceptedPasswords = ["sam pw"]
        let port = try await server.start()
        defer { server.stop() }
        let session = try await IMAPSession.connect(to: endpoint(port))
        try await session.authenticate(user: "sam", password: try MailPassword(serverPassword: "pw"), allowLogin: true)
        let inbox = try #require(try await session.listFolders().first { $0.name == "INBOX" })
        await #expect(throws: SyncError.self) { _ = try await session.examine(inbox) }
        await session.disconnect()
    }
}
#endif

#if DEBUG
/// Security checklist: the sentinel server password appears in no log line,
/// error or description, through PLAIN, LOGIN with a literal, refusals and
/// the plain-text refusal (D-570).
@Suite(.serialized) struct GenericSecretTests {
    @Test func sentinelPasswordAppearsNowhere() async throws {
        _ = CapturedLogs.installed
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let password = try MailPassword(serverPassword: serverSentinel)
        var errors: [String] = []

        for (accepted, plain) in [(true, true), (true, false), (false, true), (false, false)] {
            let server = genericServer(plain: plain)
            if accepted { server.acceptedPasswords = ["sam.taylor \(serverSentinel)"] }
            let port = try await server.start()
            let registry = AccountRegistry(keychain: keychain)
            let account = Account(id: .generate(), provider: .imap, email: "sam@example.net", displayName: "Sam")
            try registry.add(AccountRecord(account: account))
            try PasswordStore(keychain: keychain).save(password, for: account.id)
            let tokens = TokenProvider(tokenStore: TokenStore(keychain: keychain), registry: registry) { _ in throw OAuthError.noRefreshToken }
            let factory = SessionFactory(account: account, endpoint: .plaintextLoopbackAcceptingPasswordsForTests(port: Int(port)),
                                         tokens: tokens, serverUsername: "sam.taylor")
            do {
                let session = try await factory.open()
                _ = try await session.listFolders()
                await session.logout()
                #expect(accepted)
            } catch {
                #expect(!accepted)
                if !accepted { #expect(error as? SyncError == .serverPasswordRefused(account.id)) }
                errors += ["\(error)", String(reflecting: error)]
            }
            #expect(plain ? server.plainUsers == ["sam.taylor"] : server.loginUsers == ["sam.taylor"])
            for line in server.commandLog { errors.append(line) }
            server.stop()
            try keychain.deleteAll()
        }
        let server = genericServer(plain: false)
        let port = try await server.start()
        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: Int(port)))
        do { try await session.authenticate(user: "sam.taylor", password: password, allowLogin: true) } catch { errors += ["\(error)", String(reflecting: error)] }
        await session.disconnect()
        server.stop()

        #expect(errors.count >= 6)
        let logs = CapturedLogs.shared.all
        #expect(logs.contains { $0.contains("LOGIN") }) // the handler captured the LOGIN sign-ins
        let plainBase64 = Data(SASLPlain.response(user: "sam.taylor", password: password)).base64EncodedString()
        for text in logs + errors {
            #expect(!text.contains("Wxv") && !text.contains("Ølkj") && !text.contains("7731"), "\(text)")
            #expect(!text.contains(plainBase64), "\(text)")
        }
    }
}
#endif
