import Foundation
import Testing
@testable import StowSync

/// Pretends to be Time Machine so tests do not change real settings.
final class FakeTimeMachine: TimeMachineExclusion, @unchecked Sendable {
    private let lock = NSLock()
    private var excluded: Set<String> = []
    var failExclusion = false

    func isExcluded(_ url: URL) -> Bool { lock.withLock { excluded.contains(url.standardizedFileURL.path) } }

    func exclude(_ url: URL) throws {
        if failExclusion { throw SyncError.devStoreUnprotected(["tmutil failed"]) }
        _ = lock.withLock { excluded.insert(url.standardizedFileURL.path) }
    }
}

@Suite struct DevStoreTests {
    let base = temporaryDirectory()

    @Test func protectAppliesEveryProtection() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("dev-raw.noindex")
        let protection = DevStoreProtection(timeMachine: FakeTimeMachine())

        #expect(throws: SyncError.devStoreUnprotected(["the folder does not exist"])) { try protection.requireProtected(root) }
        let status = try protection.protect(root)
        #expect(status.isProtected)
        #expect(status.excludedFromTimeMachine && status.spotlightMarkerPresent && status.noindexSuffix)
        try protection.requireProtected(root)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        // Running it again changes nothing.
        #expect(try protection.protect(root).isProtected)
    }

    @Test func refusesWhenAProtectionIsMissing() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("dev-raw.noindex")
        let timeMachine = FakeTimeMachine()
        let protection = DevStoreProtection(timeMachine: timeMachine)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Folder exists but nothing applied yet.
        #expect(throws: SyncError.self) { try protection.requireProtected(root) }
        try protection.protect(root)
        // Someone deletes the Spotlight marker: sync must refuse again.
        try FileManager.default.removeItem(at: root.appendingPathComponent(DevStoreProtection.spotlightMarker))
        #expect(throws: SyncError.devStoreUnprotected(["no .metadata_never_index file"])) { try protection.requireProtected(root) }
    }

    @Test func failedTimeMachineExclusionBlocksSync() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let timeMachine = FakeTimeMachine()
        timeMachine.failExclusion = true
        let protection = DevStoreProtection(timeMachine: timeMachine)
        let root = base.appendingPathComponent("dev-raw.noindex")
        #expect(throws: SyncError.self) { try protection.protect(root) }
        #expect(throws: SyncError.self) { try protection.requireProtected(root) }
    }

    @Test func refusesRepositoriesAndNamesWithoutNoindex() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let protection = DevStoreProtection(timeMachine: FakeTimeMachine())
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(throws: SyncError.devStoreUnprotected(["inside a git repository"])) {
            try protection.protect(repo.appendingPathComponent("mail/dev-raw.noindex"))
        }
        #expect(throws: SyncError.self) { try protection.protect(base.appendingPathComponent("dev-raw")) }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("dev-raw").path))
    }

    @Test func defaultLocationIsOutsideRepositoriesAndICloud() {
        let root = DevStoreProtection.defaultRoot
        #expect(root.path.hasSuffix("Library/Application Support/Stow/dev-raw.noindex"))
        #expect(!DevStoreProtection.isInsideGitRepository(root))
        #expect(!DevStoreProtection.isInsideICloudDrive(root))
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(DevStoreProtection.isInsideICloudDrive(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x.noindex")))
        // This test file lives in a git repository.
        #expect(DevStoreProtection.isInsideGitRepository(URL(fileURLWithPath: #filePath)))
    }

    /// The real tmutil, on a scratch folder. Skipped if tmutil is unavailable.
    @Test func realTimeMachineExclusion() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/tmutil") else { return }
        let root = base.appendingPathComponent("tm-check.noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tmutil = TMUtil()
        try tmutil.exclude(root)
        #expect(tmutil.isExcluded(root))
    }
}

@Suite struct StateDirectoryTests {
    @Test func stateDirectoryIsPrivateAndExcludedFromTimeMachine() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let timeMachine = FakeTimeMachine()
        let protection = DevStoreProtection(timeMachine: timeMachine)
        let state = base.appendingPathComponent("Stow/sync-state")
        #expect(!protection.isStateDirectoryExcluded(state))
        #expect(try protection.protectStateDirectory(state))
        #expect(protection.isStateDirectoryExcluded(state))
        let permissions = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        // The parent (Track B's archive root) is left alone.
        #expect(!timeMachine.isExcluded(base.appendingPathComponent("Stow")))
    }

    /// The development store and sync state never share a name with Track B's archive files (D-119).
    @Test func namesDoNotCollideWithTheArchive() {
        let stow = DevStoreProtection.defaultRoot.deletingLastPathComponent()
        #expect(DevStoreProtection.defaultStateDirectory.deletingLastPathComponent() == stow)
        let ours = [DevStoreProtection.defaultRoot.lastPathComponent, DevStoreProtection.defaultStateDirectory.lastPathComponent]
        for name in ["archive.sqlite", "archive.sqlite-wal", "archive.sqlite-shm", "raw", "attachments", ".metadata_never_index"] {
            #expect(!ours.contains(name))
        }
    }
}
