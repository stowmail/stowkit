import CryptoKit
import Foundation
import StowCore
@testable import StowEngine
import StowSecrets
import StowStore
import StowTestSupport
import Testing

/// A-10 (D-509): moving the archive holds the writer lock to the end, leaves a
/// marker in the old folder, and warns about an agent pinned to it.
@Suite(.serialized) struct ArchiveMoveTests {
    let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
    let old = ArchiveLocation(root: TestFixtures.temporaryDirectory())
    let parent = TestFixtures.temporaryDirectory()
    var destination: URL { parent.appendingPathComponent("moved", isDirectory: true) }
    let settings = ArchiveSettings(defaults: UserDefaults(suiteName: "ee.getstow.tests.\(UUID().uuidString)")!)
    let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Sam")

    func cleanUp() {
        try? FileManager.default.removeItem(at: old.root)
        try? FileManager.default.removeItem(at: parent)
    }

    /// An archive with an account and a confirmed recovery key.
    func makeArchive() throws -> Archive {
        let archive = try Archive.open(old, keys: keys)
        try archive.register(account)
        try RecoveryBundle.write(keys, archiveID: try archive.archiveID(), recoveryKey: .generate(), to: old.root)
        try ArchiveSetup.markConfirmed(archive)
        return archive
    }

    func move(_ archive: Archive, agent: [String: String] = [:], lines: LineLog = LineLog(),
              deleting: Bool = true, whileAsked: () -> Void = {}) throws -> ArchiveRelocation.Outcome {
        try ArchiveRelocation.move(archive, to: destination, keys: keys, environment: [:], agentEnvironment: agent,
                                   settings: settings, say: { lines.add($0) }) { question in
            lines.add(question)
            whileAsked()
            return deleting
        }
    }

    /// The daemon's next turn cannot write to the old copy: while the user is
    /// asked it cannot get the lock, and afterwards the old folder is refused.
    @Test func aSecondWriterCannotWriteToTheOldCopy() throws {
        defer { cleanUp() }
        let archive = try makeArchive()
        let lock = try ArchiveLock.acquire(old)
        var busyWhileAsked = false
        let outcome = try move(archive) {
            busyWhileAsked = (try? ArchiveLock.acquire(old)) == nil
        }
        lock.release()
        #expect(outcome == .moved(deletedOld: true))
        #expect(busyWhileAsked)
        #expect(settings.chosenFolder?.path == destination.path)
        // The lock is free now, but the folder is not an archive any more.
        let second = try ArchiveLock.acquire(old)
        defer { second.release() }
        #expect(throws: ArchiveLocationError.moved(destination.path)) { try Archive.open(old, keys: keys) }
        #expect(!old.exists)
        #expect(old.movedTo() == destination.path)
        let moved = try Archive.open(ArchiveLocation(root: destination), keys: keys)
        #expect(try ArchiveAccounts(archive: moved).all().map(\.account) == [account])
    }

    /// Opening, creating or choosing a moved folder names the new place.
    @Test func aMovedFolderIsRefusedEverywhere() throws {
        defer { cleanUp() }
        let archive = try makeArchive()
        _ = try move(archive)
        let error = ArchiveLocationError.moved(destination.path)
        #expect(error.description.contains(destination.path))
        #expect(throws: error) { try Archive.open(old, keys: keys, readOnly: true) }
        #expect(throws: error) { try ArchiveOpening.requireArchive(at: old, environment: [:], settings: settings) }
        let keychain = KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
        defer { try? keychain.deleteAll() }
        #expect(throws: error) { try ArchiveSetup.createArchive(old, keyManager: KeyManager(keychain: keychain)) }
        #expect(try !KeyManager(keychain: keychain).keysExist())
        #expect(!old.exists)
    }

    /// A scheduler that opened the old copy before the move stops at its next
    /// turn, so the daemon exits and starts afresh at the new place.
    @Test func aSchedulerHoldingTheOldCopyStops() async throws {
        defer { cleanUp() }
        let archive = try makeArchive()
        let early = try Archive.open(old, keys: keys)
        let rounds = Counter()
        let scheduler = Scheduler(openArchive: { early },
                                  makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                  power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) },
                                  sleep: { _ in
                                      // A scheduler that never notices the move must fail the test, not hang it.
                                      if rounds.add() > 3 { throw CancellationError() }
                                  })
        _ = try move(archive, deleting: false)
        #expect(await scheduler.round().0 == .moved(destination.path))
        #expect(await scheduler.run() == .archiveMoved)
    }

    /// An installed agent pinned to the old folder is warned about, before the
    /// deletion question; one pinned to the destination, or not pinned, is not.
    @Test func anAgentPinnedElsewhereIsWarnedAbout() throws {
        defer { cleanUp() }
        let plist = parent.appendingPathComponent("agent.plist")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try LaunchAgent.encoded(executable: URL(fileURLWithPath: "/usr/local/bin/stowmail"),
                                environment: ["STOW_ARCHIVE_DIR": old.root.path, "STOW_KEYCHAIN": "file"]).write(to: plist)
        let agent = LaunchAgent.installedEnvironment(plist: plist)
        #expect(agent["STOW_ARCHIVE_DIR"] == old.root.path)

        let lines = LineLog()
        _ = try move(try makeArchive(), agent: agent, lines: lines)
        let warning = try #require(lines.all.firstIndex { $0.hasPrefix("Warning: ") })
        let question = try #require(lines.all.firstIndex { $0.hasPrefix("Delete the old copy") })
        #expect(warning < question)
        #expect(lines.all[warning].contains("STOW_ARCHIVE_DIR=\(destination.path) stowmail daemon install"))
        #expect(lines.all[question].contains("The background sync waits until you answer"))

        #expect(ArchiveRelocation.agentWarning(agentEnvironment: ["STOW_ARCHIVE_DIR": destination.path], destination: destination) == nil)
        #expect(ArchiveRelocation.agentWarning(agentEnvironment: ["STOW_KEYCHAIN": "file"], destination: destination) == nil)
    }

    /// With STOW_ARCHIVE_DIR set in the shell nothing switches, no marker is left, the old copy stays.
    @Test func aShellPinnedFolderIsOnlyCopied() throws {
        defer { cleanUp() }
        let archive = try makeArchive()
        let outcome = try ArchiveRelocation.move(archive, to: destination, keys: keys, environment: ["STOW_ARCHIVE_DIR": old.root.path],
                                                 agentEnvironment: [:], settings: settings, say: { _ in }) { _ in true }
        #expect(outcome == .copiedOnly)
        #expect(old.movedTo() == nil && old.exists)
        #expect(settings.chosenFolder == nil)
    }
}

final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() -> Int { lock.withLock { value += 1; return value } }
}
