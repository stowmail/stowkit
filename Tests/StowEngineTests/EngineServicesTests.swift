import CryptoKit
import Foundation
import GRDB
import Logging
import StowCore
@testable import StowEngine
import StowRules
import StowSecrets
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

func testKeychain() -> KeychainStore {
    KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
}

/// Step 1a (D-007, D-031): the recovery key, end to end.
@Suite(.serialized) struct ArchiveSetupTests {
    /// The brief's test: create an archive, delete the Keychain keys under a
    /// test service name, recover, and open the archive.
    @Test func recoveringOntoANewMacOpensTheArchive() throws {
        let keychain = testKeychain()
        defer { try? keychain.deleteAll() }
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let manager = KeyManager(keychain: keychain)

        let (archive, shown) = try ArchiveSetup.initialise(location, keyManager: manager)
        let recoveryKey = try #require(shown)
        #expect(throws: ArchiveSetupError.recoveryNotConfirmed) { try ArchiveSetup.requireConfirmed(archive) }
        try ArchiveSetup.markConfirmed(archive)
        try ArchiveSetup.requireConfirmed(archive)
        try archive.register(Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "S"))
        let archiveID = try archive.archiveID()
        try archive.database.close()
        // Running init again does not show a new key once one is confirmed.
        #expect(try ArchiveSetup.initialise(location, keyManager: manager).recoveryKey == nil)

        // A new Mac: no keys in its Keychain.
        try keychain.deleteAll()
        #expect(throws: KeyManagerError.keysMissing(backend: keychain.backend, service: keychain.service)) { try manager.loadKeys() }
        #expect(throws: ArchiveSetupError.archiveWithoutKeys(location.root.path)) { try ArchiveSetup.initialise(location, keyManager: manager) }
        #expect(throws: RecoveryBundleError.wrongKey) {
            try ArchiveSetup.recover(archiveFolder: location.root, recoveryKey: RecoveryKey.generate(), keyManager: manager)
        }
        #expect(try ArchiveSetup.recover(archiveFolder: location.root, recoveryKey: try RecoveryKey(recoveryKey.displayString), keyManager: manager) == archiveID)
        let reopened = try Archive.open(location, keys: try manager.loadKeys())
        #expect(try reopened.archiveID() == archiveID)
        #expect(try ArchiveAccounts(archive: reopened).all().count == 1)
        // Recovery never overwrites keys that are there.
        #expect(throws: KeyManagerError.keysAlreadyExist) {
            try ArchiveSetup.recover(archiveFolder: location.root, recoveryKey: recoveryKey, keyManager: manager)
        }
    }

    /// R7 (D-055, D-084): archive and keys first, then an account, then the
    /// recovery key; nothing is imported until it is confirmed.
    @Test func archiveThenAccountThenRecoveryKey() async throws {
        let keychain = testKeychain()
        defer { try? keychain.deleteAll() }
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let manager = KeyManager(keychain: keychain)
        let paused = RoundResult.paused(ArchiveSetupError.recoveryNotConfirmed.description)

        let archive = try ArchiveSetup.createArchive(location, keyManager: manager)
        #expect(!RecoveryBundle.exists(in: location.root))
        #expect(ArchiveSetup.recoveryState(archive) == .none)
        try ArchiveAccounts(archive: archive).add(AccountRecord(account: Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "S")))
        #expect(throws: ArchiveSetupError.recoveryNotConfirmed) { try ArchiveSetup.requireConfirmed(archive) }
        let scheduler = Scheduler(openArchive: { try Archive.open(location, keys: try manager.loadKeys()) },
                                  makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                  power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        #expect(await scheduler.round().0 == paused)
        // Creating again makes no key and keeps the account.
        #expect(ArchiveSetup.recoveryState(try ArchiveSetup.createArchive(location, keyManager: manager)) == .none)

        let stale = try ArchiveSetup.makeRecoveryKey(archive, keyManager: manager)
        let key = try ArchiveSetup.makeRecoveryKey(archive, keyManager: manager)
        #expect(ArchiveSetup.recoveryState(archive) == .unconfirmed)
        let groups = key.groups
        #expect(throws: ArchiveSetupError.tooFewGroups) { try ArchiveSetup.confirm(archive, recoveryKey: key, typed: [3: groups[3]]) }
        #expect(throws: ArchiveSetupError.groupMismatch) {
            try ArchiveSetup.confirm(archive, recoveryKey: key, typed: [3: groups[3], 10: groups[9]])
        }
        // A key from an earlier attempt matches its own groups but no longer opens the bundle.
        #expect(throws: ArchiveSetupError.notCurrentRecoveryKey) {
            try ArchiveSetup.confirm(archive, recoveryKey: stale, typed: [0: stale.groups[0], 13: stale.groups[13]])
        }
        #expect(throws: ArchiveSetupError.recoveryNotConfirmed) { try ArchiveSetup.requireConfirmed(archive) }

        try ArchiveSetup.confirm(archive, recoveryKey: key, typed: [3: groups[3].lowercased(), 10: groups[10]])
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
        try ArchiveSetup.requireConfirmed(archive)
        #expect(await scheduler.round().0 != paused)
        #expect(try ArchiveSetup.initialise(location, keyManager: manager).recoveryKey == nil)
        let archiveID = try archive.archiveID()
        try archive.database.close()

        // A new Mac opens it with the confirmed key, accounts included.
        try keychain.deleteAll()
        #expect(try ArchiveSetup.recover(archiveFolder: location.root, recoveryKey: key, keyManager: manager) == archiveID)
        #expect(try ArchiveAccounts(archive: try Archive.open(location, keys: try manager.loadKeys())).all().count == 1)
    }

    @Test func rotatingUnconfirmsAndOnlyTheNewKeyWorks() throws {
        let keychain = testKeychain()
        defer { try? keychain.deleteAll() }
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let manager = KeyManager(keychain: keychain)
        let (archive, first) = try ArchiveSetup.initialise(location, keyManager: manager)
        try ArchiveSetup.markConfirmed(archive)
        let second = try ArchiveSetup.rotate(archive, keys: try manager.loadKeys())
        #expect(!ArchiveSetup.isConfirmed(archive))
        #expect(throws: RecoveryBundleError.wrongKey) { try RecoveryBundle.unwrap(in: location.root, with: try #require(first)) }
        #expect(try RecoveryBundle.unwrap(in: location.root, with: second).archiveID == archive.archiveID())
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let (a, b) = ArchiveSetup.confirmationGroups(using: &generator)
            #expect(a < b && b < RecoveryKey.groupCount)
        }
    }

    /// Security review M-1 (D-086): a confirmation names the bundle it confirmed,
    /// so a bundle replaced without one, as by a rotation that wrote the new
    /// bundle and then failed, never reads as confirmed.
    @Test func aReplacedBundleIsNotConfirmed() throws {
        let keychain = testKeychain()
        defer { try? keychain.deleteAll() }
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let manager = KeyManager(keychain: keychain)
        let archive = try ArchiveSetup.createArchive(location, keyManager: manager)
        let key = try ArchiveSetup.makeRecoveryKey(archive, keyManager: manager)
        try ArchiveSetup.confirm(archive, recoveryKey: key, typed: [0: key.groups[0], 5: key.groups[5]])
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)

        // The new bundle is written but the confirmation is never cleared.
        try RecoveryBundle.write(try manager.loadKeys(), archiveID: try archive.archiveID(), recoveryKey: RecoveryKey.generate(), to: location.root)
        #expect(ArchiveSetup.recoveryState(archive) == .unconfirmed)
        #expect(throws: ArchiveSetupError.recoveryNotConfirmed) { try ArchiveSetup.requireConfirmed(archive) }

        // A rotation that cannot write its bundle leaves the archive unconfirmed, never confirmed.
        let next = try ArchiveSetup.makeRecoveryKey(archive, keyManager: manager)
        try ArchiveSetup.confirm(archive, recoveryKey: next, typed: [1: next.groups[1], 2: next.groups[2]])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: location.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: location.root.path) }
        #expect(throws: (any Error).self) { try ArchiveSetup.rotate(archive, keys: try manager.loadKeys()) }
        #expect(ArchiveSetup.recoveryState(archive) == .unconfirmed)

        // Confirmations made before D-086 recorded no bundle and still count.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: location.root.path)
        try ArchiveSetup.markConfirmed(archive)
        try archive.setMeta(ArchiveSetup.confirmedBundleKey, nil)
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
    }

    @Test func phase1AccountsMoveIntoTheArchiveKeepingTheirTokens() throws {
        let keychain = testKeychain()
        defer { try? keychain.deleteAll() }
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let registry = AccountRegistry(keychain: keychain)
        let tokens = TokenStore(keychain: keychain)
        let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Personal")
        try registry.add(AccountRecord(account: account, needsSignIn: true))
        try tokens.save(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: nil), for: account.id)

        let (archive, _) = try ArchiveSetup.initialise(location, keyManager: KeyManager(keychain: keychain))
        #expect(try ArchiveSetup.adoptKeychainAccounts(archive, registry: registry) == 1)
        let moved = try #require(try ArchiveAccounts(archive: archive).record(account.id))
        #expect(moved.account == account && moved.needsSignIn)
        #expect(try registry.all().isEmpty) // the Keychain no longer lists it
        #expect(try tokens.tokens(for: account.id) != nil) // its tokens stay
    }
}

/// Step 5 (D-036, D-037): the scheduler.
@Suite(.serialized) struct SchedulerTests {
    final class Power: @unchecked Sendable {
        var state = PowerState(onBattery: false, batteryPercent: 100, lowPowerMode: false)
    }

    func confirmedArchive() throws -> (Archive, ArchiveLocation, ArchiveKeys) {
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        let archive = try Archive.open(location, keys: keys)
        try RecoveryBundle.write(keys, archiveID: try archive.archiveID(), recoveryKey: RecoveryKey.generate(), to: location.root)
        try ArchiveSetup.markConfirmed(archive)
        return (archive, location, keys)
    }

    @Test func roundRobinTakesTurnsUntilEveryAccountIsDone() async throws {
        let fixtures = try TestFixtures.small()
        let (archive, location, keys) = try confirmedArchive()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let gmail = gmailServer(fixtures)
        let microsoft = FakeIMAPServer(mailboxes: [
            .init(name: "INBOX", attributes: [], uidValidity: 3, messages: fixtures.prefix(10).enumerated().map { .init(uid: UInt32($0.offset + 1), bytes: $0.element.bytes) }),
        ])
        microsoft.capabilities = ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR"]
        let ports = [Provider.gmail: Int(try await gmail.start()), .microsoft: Int(try await microsoft.start())]
        defer { gmail.stop(); microsoft.stop() }
        let accounts = ArchiveAccounts(archive: archive)
        try accounts.add(AccountRecord(account: Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "G")))
        try accounts.add(AccountRecord(account: Account(id: .generate(), provider: .microsoft, email: "sam@example.org", displayName: "M")))
        try archive.database.close()

        let power = Power()
        let scheduler = Scheduler(
            settings: SchedulerSettings(turn: 0), // yield after every batch: turns alternate
            openArchive: { try Archive.open(location, keys: keys) },
            makeSync: { archive in
                EngineSync(archive: archive, settingsURL: location.root.appendingPathComponent("none.json"), sleep: { _ in }) { account in
                    {
                        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: ports[account.provider]!))
                        try await session.authenticate(user: account.email, accessToken: "good-token")
                        return session
                    }
                }
            },
            power: { power.state },
            sleep: { _ in }
        )

        var rounds = 0
        var last: RoundResult = .worked
        while last == .worked, rounds < 100 {
            let (result, outcomes) = await scheduler.round()
            #expect(outcomes.count == 2) // both accounts get a turn every round
            last = result
            rounds += 1
        }
        #expect(last == .idle)
        #expect(rounds > 2) // the work was spread over several rounds
        let check = try Archive.open(location, keys: keys)
        let total = try await check.database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") }
        #expect(total == fixtures.count + 10)
        #expect(try ArchiveAccounts(archive: check).all().allSatisfy { $0.isConnected })
        #expect(try check.meta("daemon_heartbeat") != nil)
        let statuses = try ArchiveStatus.collect(check)
        #expect(statuses.allSatisfy { $0.firstSyncComplete && $0.lastError == nil && $0.queue.queued == 0 })
        #expect(statuses.allSatisfy { $0.coverageDate != nil })

        // Low battery or Low Power Mode pauses everything.
        power.state = PowerState(onBattery: true, batteryPercent: 15, lowPowerMode: false)
        guard case .paused = await scheduler.round().0 else { Issue.record("should pause on low battery"); return }
        power.state = PowerState(onBattery: false, batteryPercent: 15, lowPowerMode: true)
        guard case .paused = await scheduler.round().0 else { Issue.record("should pause in Low Power Mode"); return }
    }

    @Test func aFailingAccountWaitsLongerEachTimeAndTheOthersCarryOn() async throws {
        let (archive, location, keys) = try confirmedArchive()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let server = gmailServer(try TestFixtures.small().prefix(3).map { $0 })
        server.acceptedTokens = ["good-token"]
        let port = Int(try await server.start())
        defer { server.stop() }
        let accounts = ArchiveAccounts(archive: archive)
        let good = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Good")
        let bad = Account(id: .generate(), provider: .gmail, email: "pat@example.com", displayName: "Bad")
        try accounts.add(AccountRecord(account: good))
        try accounts.add(AccountRecord(account: bad))

        final class Clock: @unchecked Sendable { var now = Date() }
        let clock = Clock()
        let scheduler = Scheduler(
            openArchive: { try Archive.open(location, keys: keys) },
            makeSync: { archive in
                EngineSync(archive: archive, settingsURL: location.root.appendingPathComponent("none.json"), sleep: { _ in }) { account in
                    {
                        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: port))
                        try await session.authenticate(user: account.email, accessToken: account.displayName == "Good" ? "good-token" : "revoked")
                        return session
                    }
                }
            },
            power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) },
            now: { clock.now }
        )
        let (_, first) = await scheduler.round()
        guard case .failed(let text)? = first[bad.id] else { Issue.record("the bad account should fail"); return }
        #expect(text.contains("rejected"))
        guard case .synced? = first[good.id] else { Issue.record("the good account should sync"); return }
        #expect(try accounts.record(bad.id).map { _ in try ArchiveStatus.collect(archive).first { $0.account.account.id == bad.id }?.lastError } != nil)

        // Next round the bad account is still waiting (five minutes).
        clock.now = clock.now.addingTimeInterval(60)
        guard case .waiting? = await scheduler.round().1[bad.id] else { Issue.record("should be waiting"); return }
        // After the wait it is tried again, and then waits twice as long.
        clock.now = clock.now.addingTimeInterval(300)
        guard case .failed? = await scheduler.round().1[bad.id] else { Issue.record("should be retried"); return }
        clock.now = clock.now.addingTimeInterval(400)
        guard case .waiting? = await scheduler.round().1[bad.id] else { Issue.record("should wait ten minutes now"); return }
    }

    @Test func offlineAndUnconfirmedArchivesPause() async throws {
        let offline = Scheduler(openArchive: { throw ArchiveLocationError.offline("/Volumes/Gone/Stow") },
                                makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        guard case .offline = await offline.round().0 else { Issue.record("should be offline"); return }

        // Missing keys are not a disconnected disk, and must not be reported as one (D-082).
        let missingKeys = KeyManagerError.keysMissing(backend: .dataProtection, service: KeychainStore.defaultService)
        let noKeys = Scheduler(openArchive: { throw missingKeys },
                               makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                               power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        #expect(await noKeys.round().0 == .cannotOpen(missingKeys.description))

        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        _ = try Archive.open(location, keys: keys)
        let unconfirmed = Scheduler(openArchive: { try Archive.open(location, keys: keys) },
                                    makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                    power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        guard case .paused(let reason) = await unconfirmed.round().0 else { Issue.record("should pause"); return }
        #expect(reason.contains("recovery key"))

        // A confirmation whose bundle has gone does not count (D-084).
        let archive = try Archive.open(location, keys: keys)
        try ArchiveSetup.markConfirmed(archive)
        try archive.database.close()
        #expect(await unconfirmed.round().0 == .paused(ArchiveSetupError.recoveryNotConfirmed.description))
    }

    /// D-036: after the budget runs out, wait only until there is room again, never under the minimum.
    @Test func aUsedUpBudgetWaitsOnlyUntilThereIsRoom() async throws {
        let (archive, location, keys) = try confirmedArchive()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "G")
        try ArchiveAccounts(archive: archive).add(AccountRecord(account: account))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ArchiveSyncStore(archive: archive)
        try await store.recordDownload(account.id, bytes: 500, at: now.addingTimeInterval(-86_000))
        try await store.recordDownload(account.id, bytes: 500, at: now.addingTimeInterval(-3_600))
        let scheduler = Scheduler(openArchive: { try Archive.open(location, keys: keys) },
                                  makeSync: { _ in throw CocoaError(.fileNoSuchFile) }, now: { now })
        // The first 500 bytes age out in 400 seconds.
        #expect(await scheduler.budgetWait(archive, account: account.id, mustFree: 200) == now.addingTimeInterval(400))
        // The second only in almost a day.
        #expect(await scheduler.budgetWait(archive, account: account.id, mustFree: 800) == now.addingTimeInterval(82_800))
        // Never sooner than the minimum, and an hour if it can never fit.
        try await store.recordDownload(account.id, bytes: 1, at: now.addingTimeInterval(-86_390))
        #expect(await scheduler.budgetWait(archive, account: account.id, mustFree: 1) == now.addingTimeInterval(300))
        #expect(await scheduler.budgetWait(archive, account: account.id, mustFree: 5_000) == now.addingTimeInterval(3600))
    }

    /// Files from a batch killed before it was recorded are deleted when the daemon starts.
    @Test func theFirstRoundDeletesFilesLeftByAKilledSync() async throws {
        let (archive, location, keys) = try confirmedArchive()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let content = Data("left behind".utf8)
        _ = try archive.attachmentFiles.write(content, hash: archive.attachmentFiles.hash(of: content))
        try archive.database.close()
        let scheduler = Scheduler(openArchive: { try Archive.open(location, keys: keys) },
                                  makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                  power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        #expect(await scheduler.round().0 == .idle)
        let check = try Archive.open(location, keys: keys)
        #expect(check.attachmentFiles.allHashes().isEmpty)
        #expect(try ArchiveVerifier(archive: check).run().unusedAttachmentFiles == 0)
    }
}

@Suite struct DaemonPieceTests {
    /// The daemon runs a copy, so a rebuild never changes the binary macOS trusts; its log is private.
    @Test func installCopiesTheBinaryAndKeepsTheLogPrivate() throws {
        let root = TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent(".build/Debug")
        let build = products.appendingPathComponent("stowmail")
        for folder in ["SQLCipher.framework/Versions/A", "SQLCipher.framework.dSYM", "StowKit_StowRules.bundle", "StowSyncTests.xctest"] {
            try FileManager.default.createDirectory(at: products.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("library".utf8).write(to: products.appendingPathComponent("SQLCipher.framework/Versions/A/SQLCipher"))
        try Data("rules".utf8).write(to: products.appendingPathComponent("StowKit_StowRules.bundle/rules.json"))
        try Data().write(to: products.appendingPathComponent("libStowCore.a"))
        try Data("first build".utf8).write(to: build)
        let installed = root.appendingPathComponent("support/bin/stowmail")
        try LaunchAgent.copyExecutable(build, to: installed)
        try Data("second build".utf8).write(to: build)
        #expect(try Data(contentsOf: installed) == Data("first build".utf8))
        try LaunchAgent.copyExecutable(build, to: installed)
        #expect(try Data(contentsOf: installed) == Data("second build".utf8))
        // What the binary loads beside itself comes too; debug symbols, tests and static libraries do not.
        let bin = installed.deletingLastPathComponent()
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: bin.path)) == ["stowmail", "SQLCipher.framework", "StowKit_StowRules.bundle"])
        #expect(try Data(contentsOf: bin.appendingPathComponent("SQLCipher.framework/Versions/A/SQLCipher")) == Data("library".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.deletingLastPathComponent().path) == ["bin"])

        let log = root.appendingPathComponent("daemon.out.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o644])
        try LaunchAgent.createPrivateFile(log)
        #expect(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int == 0o600)
    }

    /// Security checklist: the launchd plist has no secrets in it.
    @Test func launchAgentPlistHoldsNoSecrets() throws {
        let environment = [
            "STOW_KEYCHAIN": "file", "STOW_ENV_FILE": "/Users/sam/stow/engine/.env",
            "STOW_GOOGLE_CLIENT_SECRET": "very-secret-value", "STOW_MS_CLIENT_ID": "1234-abcd", "HOME": "/Users/sam",
            "ACCESS_TOKEN": "ya29.a0AfH6SMBexampletoken",
        ]
        let data = try LaunchAgent.encoded(executable: URL(fileURLWithPath: "/usr/local/bin/stowmail"), environment: environment)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("very-secret-value") && !text.contains("1234-abcd") && !text.contains("ya29."))
        #expect(!text.contains("HOME"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(Set((plist["EnvironmentVariables"] as? [String: String] ?? [:]).keys) == ["STOW_KEYCHAIN", "STOW_ENV_FILE"])
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["Nice"] as? Int == 10)
        #expect(plist["LowPriorityIO"] as? Bool == true)
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/bin/stowmail", "daemon", "run"])
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    }

    /// D-082: reinstalling from a shell without STOW_KEYCHAIN keeps the old agent's keychain.
    @Test func reinstallKeepsSettingsTheShellDoesNotSet() {
        let previous = ["STOW_KEYCHAIN": "file", "STOW_ENV_FILE": "/old/.env", "STOW_LOG_LEVEL": "debug"]
        let current = ["STOW_ENV_FILE": "/new/.env", "STOW_LOG_LEVEL": "", "HOME": "/Users/sam"]
        let (environment, change) = LaunchAgent.reinstallEnvironment(current: current, previous: previous)
        #expect(environment == ["STOW_KEYCHAIN": "file", "STOW_ENV_FILE": "/new/.env"])
        #expect(change.kept == ["STOW_KEYCHAIN=file"])
        #expect(change.changed == ["STOW_ENV_FILE: /old/.env to /new/.env"])
        #expect(change.removed == ["STOW_LOG_LEVEL=debug"])
        #expect(LaunchAgent.reinstallEnvironment(current: ["STOW_KEYCHAIN": "file"], previous: [:]).change == .init())
    }

    /// Step 8: the log file is redacted even if a caller slips.
    @Test func logFileIsScrubbedAndPrivate() throws {
        let url = TestFixtures.temporaryDirectory().appendingPathComponent("stowmail.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handler = FileLogHandler(label: "test", file: LogFile(url: url), level: .debug)
        let logger = Logger(label: "test") { _ in handler }
        logger.warning("Server said Bearer abcdefghijklmnopqrstuvwxyz0123456789ABCD for sam@example.com",
                       metadata: ["detail": "contact pat@example.org", "account": "1234"])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("warning test:") && text.contains("account=1234"))
        #expect(!text.contains("sam@example.com") && !text.contains("pat@example.org") && !text.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
    }

    /// Security review M-2: standard error is scrubbed too, since MCP clients
    /// and launchd keep it in files of their own.
    @Test func standardErrorIsScrubbed() throws {
        let url = TestFixtures.temporaryDirectory().appendingPathComponent("stderr.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let capture = try FileHandle(forWritingTo: url)
        let saved = dup(STDERR_FILENO)
        dup2(capture.fileDescriptor, STDERR_FILENO)
        let logger = Logger(label: "test") { label in StandardErrorLogHandler(label: label, level: .debug) }
        logger.warning("Server said Bearer abcdefghijklmnopqrstuvwxyz0123456789ABCD for sam@example.com",
                       metadata: ["detail": "contact pat@example.org"])
        dup2(saved, STDERR_FILENO)
        close(saved)
        try capture.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("warning test:"))
        #expect(!text.contains("sam@example.com") && !text.contains("pat@example.org") && !text.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
    }

    @Test func powerPausesOnLowBatteryOrLowPowerMode() {
        #expect(PowerState(onBattery: false, batteryPercent: 5, lowPowerMode: false).pauseReason == nil) // charging
        #expect(PowerState(onBattery: true, batteryPercent: 20, lowPowerMode: false).pauseReason == nil)
        #expect(PowerState(onBattery: true, batteryPercent: 19, lowPowerMode: false).pauseReason != nil)
        #expect(PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: true).pauseReason != nil)
        _ = PowerState.current() // must not crash, battery or not
    }

    @Test func retentionStepsMatchTheMailbox() throws {
        #expect(RetentionGuide.kind(provider: .gmail, email: "sam@gmail.com") == .gmail)
        #expect(RetentionGuide.kind(provider: .gmail, email: "sam@getstow.ee") == .googleWorkspace)
        #expect(RetentionGuide.kind(provider: .microsoft, email: "sam@outlook.com") == .outlookCom)
        #expect(RetentionGuide.kind(provider: .microsoft, email: "sam@company.example") == .microsoft365)
        let date = try #require(ISO8601DateFormatter().date(from: "2025-10-13T12:00:00Z"))
        let steps = RetentionGuide.steps(.gmail, before: date)
        #expect(steps.contains { $0.contains("before:2025/10/13") })
        #expect(steps.first?.contains("Conversation view") == true)
        let warning = RetentionGuide.warning(count: 23_410, bytes: 9_800_000_000, lastBackup: Date().addingTimeInterval(-16 * 86_400))
        #expect(warning.contains("only copy of these 23410 emails") && warning.contains("16 days"))
        #expect(TimeMachineStatus.parse("/Volumes/Backup/2026-10-22-103000.backup") != nil)
        #expect(TimeMachineStatus.parse("nothing") == nil)
    }
}

/// D-028, D-041, step 9: the rules on archived mail.
@Suite(.serialized) struct EngineRulesTests {
    @Test func bulkMailIsDownloadedLast() throws {
        let set = RuleSet.standard
        let prioritise = EngineRules.prioritiser(set, ownAddress: "sam@example.com")
        func fields(_ prefix: String) throws -> Data {
            FakeIMAPServer.headerFields(of: try TestFixtures.data(prefix), named: PriorityHeaderFields.names)
        }
        #expect(prioritise(try fields("01-")) == 0)
        #expect(prioritise(try fields("18-")) == 1)
        #expect(prioritise(try fields("25-")) == 2)
    }

    @Test func reportRunsTheRulesOverTheArchiveAndStoresThem() async throws {
        let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: location.root) }
        let archive = try Archive.open(location, keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        let account = Account(id: .generate(), provider: .microsoft, email: "sam@example.com", displayName: "S")
        try archive.register(account)
        let importer = Importer(archive: archive) // no classifier: nothing stored yet
        for (index, fixture) in try TestFixtures.all().enumerated() {
            _ = try importer.importMessage(RawMessage(key: RawMessageKey(accountID: account.id, folder: "INBOX", uidValidity: 1, uid: UInt32(index + 1)),
                                                      internalDate: Date(), size: fixture.bytes.count, bytes: fixture.bytes))
        }
        let settings = location.root.appendingPathComponent("rules.json")
        try RuleOverrides(archive: archive).set("example.net", .keep)
        let report = try RulesRunner.run(archive, settings: settings)
        #expect(report.messages == 25 && report.unreadable == 0)
        #expect(report.bySuggestion[.deprioritise]?.messages ?? 0 >= 1)
        #expect(report.signalCounts[.listUnsubscribe] ?? 0 >= 2)
        // Reasons name domains at most, never full addresses.
        let reasons = report.bySuggestion.values.flatMap(\.topReasons).map(\.reason)
        #expect(!reasons.contains { $0.contains("@") })
        let stored = try await archive.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE rule_suggestion IS NOT NULL")
        }
        #expect(stored == 25)
        // The archive's overrides were applied.
        #expect(try EngineRules.ruleSet(settings: settings, archive: archive, account: account.id).senderOverrides.first?.match == "example.net")
    }
}
