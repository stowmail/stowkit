import Foundation
import StowCore
import StowSecrets
import StowTestSupport
import Testing
@testable import StowSync

// Against the two local Dovecot servers from `scripts/dovecot-test.sh` (brief
// QA), only when `STOW_DOVECOT=1`, so `scripts/check.sh` never needs them.
// Debug only: sign-in goes over the plain-text loopback endpoint (D-471);
// TLS on 31993 is used only to check its self-signed certificate is refused.
#if DEBUG
enum Dovecot {
    static let enabled = ProcessInfo.processInfo.environment["STOW_DOVECOT"] == "1"
    static let fullPort = 31143
    static let fullTLSPort = 31993
    static let barePort = 32143
    static let username = "sam.taylor"
    /// The fixture password in `Tests/Dovecot/users`. Synthetic, local only.
    static let password = "local-dovecot-fixture"
    /// The seed puts 25 fixtures in INBOX, Sent, Trash, Junk and Archive/2025;
    /// the 4 in Junk are not archived (D-571).
    static let archived = 21
    static let folders = ["Archive/2025", "INBOX", "Sent", "Trash"]
}

@Suite(.serialized, .enabled(if: Dovecot.enabled)) struct DovecotTests {
    /// On the bare server, Stow ignores `AUTH=PLAIN` (debug only) so it sends `LOGIN`.
    func open(port: Int) -> @Sendable () async throws -> IMAPSession {
        {
            let session = try await IMAPSession.connect(to: .plaintextLoopbackAcceptingPasswordsForTests(port: port), timeouts: IMAPTimeouts(connect: 5, read: 10))
            if port == Dovecot.barePort { await session.ignoreAuthPlainForTests() }
            try await session.authenticate(user: Dovecot.username, password: try MailPassword(serverPassword: Dovecot.password), allowLogin: true)
            return session
        }
    }

    func account() -> Account {
        Account(id: AccountID(rawValue: "dovecot-\(UUID().uuidString.prefix(8).lowercased())"), provider: .imap, email: "sam@stow.test", displayName: "Sam")
    }

    /// Flags of every message in every synced folder, to show sync changed none.
    func flags(port: Int) async throws -> [String: [UInt32: [String]]] {
        let session = try await open(port: port)()
        var result: [String: [UInt32: [String]]] = [:]
        for folder in try await session.listFolders() where Dovecot.folders.contains(folder.name) || folder.name == "Junk" {
            let status = try await session.examine(folder)
            let states = status.exists == 0 ? [] : try await session.fetchStates(1...UInt32.max)
            result[folder.name] = Dictionary(uniqueKeysWithValues: states.map { ($0.uid, $0.flags.sorted()) })
        }
        await session.logout()
        return result
    }

    func syncAndVerify(port: Int, expectLogin: Bool) async throws {
        let root = temporaryDirectory(".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        let account = account()
        let before = try await flags(port: port)

        let syncer = AccountSyncer(account: account, openSession: open(port: port), sink: store, state: MemorySyncState(),
                                   budget: ByteBudget(limit: nil, fileURL: nil), sleep: { _ in })
        let report = try await syncer.run(SyncOptions(batches: BatchPlanner(maxMessages: 5)))
        #expect(report.outcome == .complete)
        #expect(report.messagesWritten == Dovecot.archived)
        let keys = try await store.listKeys()
        #expect(Set(keys.map(\.folder)) == Set(Dovecot.folders))
        #expect(Set(keys).count == keys.count)

        let verify = try await StoreVerifier(account: account, openSession: open(port: port), source: store,
                                             budget: ByteBudget(limit: nil, fileURL: nil)).run(sample: nil)
        #expect(verify.storedMessages == Dovecot.archived)
        #expect(verify.identical == Dovecot.archived)
        #expect(verify.isClean && verify.goneFromServer.isEmpty && verify.notCompared.isEmpty)

        // Brief QA: unread counts (every flag, in fact) unchanged on the server.
        #expect(try await flags(port: port) == before)
        _ = expectLogin
    }

    /// Every extension and SPECIAL-USE: PLAIN, Junk skipped by flag, Trash kept.
    @Test func fullServerSyncsAndVerifies() async throws {
        try await syncAndVerify(port: Dovecot.fullPort, expectLogin: false)
    }

    /// Brief QA: "A server with no optional capabilities syncs correctly". IMAP4rev1
    /// only, signed in with LOGIN, no SPECIAL-USE (so Junk found by name).
    @Test func bareServerSyncsWithLoginAndNoExtensions() async throws {
        let session = try await open(port: Dovecot.barePort)()
        #expect(try await session.capabilities() == ["IMAP4REV1"])
        await session.logout()
        try await syncAndVerify(port: Dovecot.barePort, expectLogin: true)
    }

    /// Brief QA: killing the process mid-sync and restarting gives no duplicates and no gaps.
    @Test func crashThenRestartLeavesNoGapsOrDuplicates() async throws {
        let root = temporaryDirectory(".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileRawMessageStore(root: root)
        let account = account()
        let state = MemorySyncState()
        func syncer(_ sink: RawMessageSink) -> AccountSyncer {
            AccountSyncer(account: account, openSession: open(port: Dovecot.fullPort), sink: sink, state: state,
                          budget: ByteBudget(limit: nil, fileURL: nil), sleep: { _ in })
        }
        await #expect(throws: CocoaError.self) {
            _ = try await syncer(CrashingSink(store, crashOnFlush: 2)).run(SyncOptions(batches: BatchPlanner(maxMessages: 3)))
        }
        let afterCrash = try await store.listKeys().count
        #expect(afterCrash > 0 && afterCrash < Dovecot.archived)
        let report = try await syncer(store).run(SyncOptions(batches: BatchPlanner(maxMessages: 3)))
        #expect(report.outcome == .complete)
        let keys = try await store.listKeys()
        #expect(keys.count == Dovecot.archived)
        #expect(Set(keys).count == keys.count)
        let verify = try await StoreVerifier(account: account, openSession: open(port: Dovecot.fullPort), source: store,
                                             budget: ByteBudget(limit: nil, fileURL: nil)).run(sample: nil)
        #expect(verify.identical == Dovecot.archived)
    }

    /// Brief step 6 against a real server: each failure its own error.
    @Test func errorsAgainstARealServer() async throws {
        // The image's self-signed certificate: refused, with no way round it.
        do {
            _ = try await IMAPSession.connect(to: IMAPEndpoint(host: "localhost", port: Dovecot.fullTLSPort))
            Issue.record("a self-signed certificate was accepted")
        } catch let error as SyncError {
            guard case .certificateRejected = error else { Issue.record("expected certificateRejected, got \(error)"); return }
        }
        // TLS to the plain-text port: the port does not speak TLS.
        do {
            _ = try await IMAPSession.connect(to: IMAPEndpoint(host: "127.0.0.1", port: Dovecot.fullPort))
            Issue.record("TLS to a plain-text port succeeded")
        } catch let error as SyncError {
            guard case .tlsHandshakeFailed = error else { Issue.record("expected tlsHandshakeFailed, got \(error)"); return }
        }
        // Nothing listening.
        do {
            _ = try await IMAPSession.connect(to: IMAPEndpoint(host: "127.0.0.1", port: 31144))
            Issue.record("connected to a closed port")
        } catch let error as SyncError {
            guard case .connectionRefused = error else { Issue.record("expected connectionRefused, got \(error)"); return }
        }
        // A wrong password, by PLAIN and by LOGIN: Dovecot's own refusal.
        for port in [Dovecot.fullPort, Dovecot.barePort] {
            let session = try await IMAPSession.connect(to: .plaintextLoopbackAcceptingPasswordsForTests(port: port))
            if port == Dovecot.barePort { await session.ignoreAuthPlainForTests() }
            do {
                try await session.authenticate(user: Dovecot.username, password: try MailPassword(serverPassword: "not-the-password"), allowLogin: true)
                Issue.record("a wrong password was accepted on \(port)")
            } catch let error as SyncError {
                guard case .authenticationFailed = error else { Issue.record("expected authenticationFailed, got \(error)"); return }
            }
            await session.disconnect()
        }
    }

    /// Step 3: what the sign-in check reports for each server.
    @Test func capabilitiesAfterSignIn() async throws {
        let full = try await open(port: Dovecot.fullPort)()
        let fullCapabilities = try await full.capabilities()
        await full.logout()
        #expect(["UIDPLUS", "CONDSTORE", "SPECIAL-USE", "ENABLE", "LIST-EXTENDED", "IDLE"].allSatisfy(fullCapabilities.contains))
        let bare = try await open(port: Dovecot.barePort)()
        #expect(try await bare.capabilities() == ["IMAP4REV1"])
        await bare.logout()
    }
}
#endif
