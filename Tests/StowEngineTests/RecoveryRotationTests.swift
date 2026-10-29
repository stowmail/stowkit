import Foundation
import StowCore
@testable import StowEngine
import StowSecrets
import StowStore
import StowTestSupport
import Testing

/// A-04 (D-480): a new recovery key waits beside the archive until it is
/// confirmed, so stopping at any point leaves a key the user holds able to
/// open `keys.recovery`.
@Suite(.serialized) struct RecoveryRotationTests {
    let keychain = testKeychain()
    let location = ArchiveLocation(root: TestFixtures.temporaryDirectory())

    func cleanUp() {
        try? keychain.deleteAll()
        try? FileManager.default.removeItem(at: location.root)
    }

    /// An archive whose first key was made and confirmed through the public API.
    func confirmedArchive() throws -> (Archive, KeyManager, RecoveryKey) {
        let manager = KeyManager(keychain: keychain)
        let (archive, shown) = try ArchiveSetup.initialise(location, keyManager: manager)
        let first = try #require(shown)
        try ArchiveSetup.confirm(archive, recoveryKey: first, typed: [0: first.groups[0], 7: first.groups[7]])
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
        return (archive, manager, first)
    }

    @Test func aNewKeyNobodyConfirmedLeavesTheOldOneWorking() throws {
        defer { cleanUp() }
        let (archive, manager, first) = try confirmedArchive()
        _ = try ArchiveSetup.rotate(archive, keys: try manager.loadKeys())
        // The user quits, or the terminal closes, before typing anything back.
        #expect(try RecoveryBundle.unwrap(in: location.root, with: first).archiveID == archive.archiveID())
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
        try ArchiveSetup.requireConfirmed(archive)
    }

    @Test func threeWrongTriesLeaveTheOldKeyWorking() throws {
        defer { cleanUp() }
        let (archive, manager, first) = try confirmedArchive()
        let second = try ArchiveSetup.rotate(archive, keys: try manager.loadKeys())
        for _ in 1...3 {
            #expect(throws: ArchiveSetupError.groupMismatch) {
                try ArchiveSetup.confirm(archive, recoveryKey: second, typed: [1: "ZZZZ", 2: second.groups[2]])
            }
        }
        #expect(try RecoveryBundle.unwrap(in: location.root, with: first).archiveID == archive.archiveID())
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
    }
}

/// Records every `DiskSync` step, and can stop at one as a power cut would.
final class DiskSyncRecorder: @unchecked Sendable {
    struct Stopped: Error {}
    private let lock = NSLock()
    private var recorded: [DiskSync.Step] = []
    private let stopAt: @Sendable (DiskSync.Step) -> Bool

    init(stopAt: @escaping @Sendable (DiskSync.Step) -> Bool = { _ in false }) {
        self.stopAt = stopAt
    }

    var steps: [DiskSync.Step] { lock.withLock { recorded } }

    var sync: DiskSync {
        DiskSync { step in
            if self.stopAt(step) { throw Stopped() }
            self.lock.withLock { self.recorded.append(step) }
        }
    }

    func clear() { lock.withLock { recorded = [] } }
}

extension RecoveryRotationTests {
    var pending: String { location.root.appendingPathComponent(RecoveryBundle.pendingFileName).path }
    var live: String { location.root.appendingPathComponent(RecoveryBundle.fileName).path }

    /// Stopped after the confirmation is recorded and before the rename: the
    /// next writer (here the scheduler's turn) finishes the rename.
    @Test func aConfirmationStoppedBeforeTheRenameIsFinishedByTheNextWriter() async throws {
        defer { cleanUp() }
        let (archive, manager, first) = try confirmedArchive()
        let pendingPath = pending
        let stopping = DiskSyncRecorder { step in
            if case .rename(let from, _) = step { return from == pendingPath }
            return false
        }
        let stopped = try Archive.open(location, keys: try manager.loadKeys(), diskSync: stopping.sync)
        let second = try ArchiveSetup.rotate(stopped, keys: try manager.loadKeys())
        #expect(throws: DiskSyncRecorder.Stopped.self) {
            try ArchiveSetup.confirm(stopped, recoveryKey: second, typed: [2: second.groups[2], 3: second.groups[3]])
        }
        // Both keys still open something: the old one the live bundle, the new one the pending bundle.
        #expect(try RecoveryBundle.unwrap(in: location.root, with: first).archiveID == archive.archiveID())
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
        #expect(!ArchiveSetup.hasUnconfirmedNewKey(archive))

        let scheduler = Scheduler(openArchive: { try Archive.open(self.location, keys: try manager.loadKeys()) },
                                  makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                  power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        _ = await scheduler.round()
        #expect(!RecoveryBundle.exists(in: location.root, name: RecoveryBundle.pendingFileName))
        #expect(try RecoveryBundle.unwrap(in: location.root, with: second).archiveID == archive.archiveID())
        #expect(throws: RecoveryBundleError.wrongKey) { try RecoveryBundle.unwrap(in: location.root, with: first) }
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
        #expect(try !ArchiveSetup.finishConfirmedKey(archive))
    }

    /// The bundle is flushed before its rename and the folder after it; the
    /// confirmation is durable before the pending bundle replaces the live one.
    @Test func bundlesAreFlushedAroundEachRenameAndTheCommitComesFirst() throws {
        defer { cleanUp() }
        let (_, manager, _) = try confirmedArchive()
        let recorder = DiskSyncRecorder()
        let archive = try Archive.open(location, keys: try manager.loadKeys(), diskSync: recorder.sync)
        let second = try ArchiveSetup.rotate(archive, keys: try manager.loadKeys())
        let root = location.root.path
        let written = recorder.steps
        #expect(written.count == 3)
        guard case .flushFile(let temporary, .full) = written.first else { Issue.record("no full flush first: \(written)"); return }
        #expect(temporary.hasPrefix(root + "/.keys.recovery.pending."))
        #expect(Array(written.dropFirst()) == [.rename(from: temporary, to: pending), .flushFolder(root, .full)])

        recorder.clear()
        try ArchiveSetup.confirm(archive, recoveryKey: second, typed: [5: second.groups[5], 6: second.groups[6]])
        #expect(recorder.steps == [.durableCommit, .rename(from: pending, to: live), .flushFolder(root, .full)])
        // The writer's connection is back on its usual settings afterwards.
        #expect(try archive.database.write { try Int.fetchOne($0, sql: "PRAGMA synchronous") } == 1)
        #expect(try archive.database.write { try Int.fetchOne($0, sql: "PRAGMA fullfsync") } == 0)
    }

    /// A key nobody confirmed is deleted when the prompt gives up, and is
    /// reported until then; the next rotation replaces it anyway.
    @Test func anUnconfirmedNewKeyIsDiscardedAndReported() throws {
        defer { cleanUp() }
        let (archive, manager, first) = try confirmedArchive()
        _ = try ArchiveSetup.rotate(archive, keys: try manager.loadKeys())
        #expect(ArchiveSetup.hasUnconfirmedNewKey(archive))
        let stale = try RecoveryBundle.fingerprint(in: location.root, name: RecoveryBundle.pendingFileName)
        let second = try ArchiveSetup.rotate(archive, keys: try manager.loadKeys())
        #expect(try RecoveryBundle.fingerprint(in: location.root, name: RecoveryBundle.pendingFileName) != stale)
        try ArchiveSetup.discardUnconfirmedKey(archive)
        #expect(!ArchiveSetup.hasUnconfirmedNewKey(archive))
        #expect(!RecoveryBundle.exists(in: location.root, name: RecoveryBundle.pendingFileName))
        #expect(throws: ArchiveSetupError.notCurrentRecoveryKey) {
            try ArchiveSetup.confirm(archive, recoveryKey: second, typed: [0: second.groups[0], 1: second.groups[1]])
        }
        #expect(try RecoveryBundle.unwrap(in: location.root, with: first).archiveID == archive.archiveID())
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
        // Leftover temporary files are never mistaken for a bundle.
        #expect(try FileManager.default.contentsOfDirectory(atPath: location.root.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    /// The first key (init, onboarding): only a pending bundle exists, which is
    /// `unconfirmed`, so nothing is imported until it is confirmed (D-084).
    @Test func aFirstKeyWaitingIsUnconfirmed() async throws {
        defer { cleanUp() }
        let manager = KeyManager(keychain: keychain)
        let (archive, shown) = try ArchiveSetup.initialise(location, keyManager: manager)
        let first = try #require(shown)
        #expect(!RecoveryBundle.exists(in: location.root))
        #expect(ArchiveSetup.recoveryState(archive) == .unconfirmed)
        #expect(throws: ArchiveSetupError.recoveryNotConfirmed) { try ArchiveSetup.requireConfirmed(archive) }
        let scheduler = Scheduler(openArchive: { try Archive.open(self.location, keys: try manager.loadKeys()) },
                                  makeSync: { _ in throw CocoaError(.fileNoSuchFile) },
                                  power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) })
        #expect(await scheduler.round().0 == .paused(ArchiveSetupError.recoveryNotConfirmed.description))
        #expect(!RecoveryBundle.exists(in: location.root))
        try ArchiveSetup.discardUnconfirmedKey(archive)
        #expect(ArchiveSetup.recoveryState(archive) == .none)
        #expect(throws: ArchiveSetupError.notCurrentRecoveryKey) {
            try ArchiveSetup.confirm(archive, recoveryKey: first, typed: [0: first.groups[0], 1: first.groups[1]])
        }
        let again = try #require(try ArchiveSetup.initialise(location, keyManager: manager).recoveryKey)
        try ArchiveSetup.confirm(archive, recoveryKey: again, typed: [0: again.groups[0], 1: again.groups[1]])
        #expect(ArchiveSetup.recoveryState(archive) == .confirmed)
        #expect(try RecoveryBundle.unwrap(in: location.root, with: again).archiveID == archive.archiveID())
    }
}
