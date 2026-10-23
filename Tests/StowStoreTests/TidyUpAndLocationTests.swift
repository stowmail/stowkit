import CryptoKit
import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Tidy-up (D-020, D-033), coverage (D-021, D-034), accounts (D-032) and
/// archive location (D-023, D-035).
@Suite(.serialized) struct TidyUpTests {
    func imported() async throws -> TestArchive {
        let test = try TestArchive()
        _ = try await Importer(archive: test.archive, classifier: { headers, _ in
            // Stand-in rules: List-Unsubscribe means "consider deleting".
            headers.listUnsubscribe == nil ? StoredRuleResult(suggestion: .keep, score: 0, signals: [])
                : StoredRuleResult(suggestion: .considerDeleting, score: 6, signals: ["listUnsubscribe"])
        }).importAll(from: MemorySource(try test.fixtureMessages()))
        return test
    }

    @Test func removingDeletesRowsFilesAndIndexButKeepsATombstone() async throws {
        let test = try await imported()
        defer { test.remove() }
        let removal = ArchiveRemoval(archive: test.archive)
        let plan = try removal.plan(.signal("listUnsubscribe"))
        let flagged = try test.count("messages", "rule_signals LIKE '%listUnsubscribe%'")
        #expect(plan.messageIDs.count == flagged)
        #expect(!plan.messageIDs.isEmpty && plan.bytes > 0)
        let before = try test.count("messages")
        let result = try removal.remove(plan.messageIDs, reason: RemovalSelector.signal("listUnsubscribe").reason)
        #expect(result.messages == plan.messageIDs.count)
        #expect(try test.count("messages") == before - plan.messageIDs.count)
        #expect(try test.count("tombstones", "reason = 'rule:listUnsubscribe'") == plan.messageIDs.count)
        #expect(try test.count("tombstone_copies") == plan.messageIDs.count)
        let verify = try ArchiveVerifier(archive: test.archive).run()
        #expect(verify.isClean)
        #expect(verify.unusedMessageFiles == 0 && verify.unusedAttachmentFiles == 0)
    }

    @Test func sharedAttachmentsSurviveRemovingOneOfTheirMessages() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let importer = Importer(archive: test.archive)
        guard case .imported(let first) = try importer.importMessage(test.raw(try Fixtures.data("06-"), uid: 1)) else { return }
        _ = try importer.importMessage(test.raw(try Fixtures.data("07-"), uid: 2))
        _ = try ArchiveRemoval(archive: test.archive).remove([first], reason: "sender:x")
        #expect(try test.count("attachments") == 1)
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
    }

    @Test func removedMailIsNeverStoredAgainUntilRestored() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = ArchiveSyncStore(archive: test.archive)
        let account = test.account.id
        _ = try await store.beginFolder(account, folder: "INBOX", uidValidity: 1, exists: 1)
        let data = try Fixtures.data("18-")
        try await store.write(test.raw(data, uid: 1))
        let removal = ArchiveRemoval(archive: test.archive)
        _ = try removal.remove(try removal.plan(.sender("example.org")).messageIDs + removal.plan(.sender("example.com")).messageIDs
                                   + removal.plan(.sender("example.net")).messageIDs, reason: "sender:test")
        #expect(try test.count("messages") == 0)

        // The same message seen at a new place (moved, or a UIDVALIDITY change) is not stored again.
        #expect(try Importer(archive: test.archive).importMessage(test.raw(data, folder: "Archive", uid: 4)) == .tombstoned)
        #expect(try test.count("messages") == 0)
        // Listing it again at a place where it was removed does not queue it.
        #expect(try await store.enqueue(account, folder: "INBOX", uidValidity: 1, messages: [
            QueuedMessage(folder: "INBOX", uidValidity: 1, uid: 1, size: 10),
        ], listedThrough: 1) == 0)

        let tombstones = try removal.tombstones()
        #expect(tombstones.count == 1)
        #expect(try removal.requestRestore(tombstones.map(\.id)) == (1, 0))
        #expect(try await store.nextDownloads(account, runID: "r", maxMessages: 10, maxBytes: 100_000).map(\.uid) == [1])
        try await store.write(test.raw(data, uid: 1))
        #expect(try test.count("messages") == 1)
        #expect(try test.count("tombstones") == 0)
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
    }

    @Test func senderSelectsAnAddressOrADomainWithItsSubdomains() async throws {
        let test = try await imported()
        defer { test.remove() }
        let removal = ArchiveRemoval(archive: test.archive)
        let domain = try removal.plan(.sender("example.com"))
        let address = try removal.plan(.sender("alex@example.com"))
        #expect(address.messageIDs.count <= domain.messageIDs.count)
        #expect(try removal.plan(.sender("xample.com")).messageIDs.isEmpty)
    }

    @Test func coverageWaitsForListingThenFollowsTheQueue() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = ArchiveSyncStore(archive: test.archive)
        let account = test.account.id
        try await store.recordFolders(account, [SyncFolder(name: "INBOX")])
        #expect(try Coverage.compute(test.archive, account: account).coverageDate == nil)

        let day: TimeInterval = 86_400
        let now = Date()
        _ = try await store.beginFolder(account, folder: "INBOX", uidValidity: 1, exists: 2)
        try await store.enqueue(account, folder: "INBOX", uidValidity: 1, messages: [
            QueuedMessage(folder: "INBOX", uidValidity: 1, uid: 1, size: 10, internalDate: now.addingTimeInterval(-400 * day)),
        ], listedThrough: 1)
        try await store.folderWalked(account, folder: "INBOX", uidValidity: 1, at: now)
        var report = try Coverage.compute(test.archive, account: account, retentionMonths: 12, now: now)
        // Held back by the queued message from 400 days ago, which is also at risk.
        #expect(report.coverageDate.map { abs($0.timeIntervalSince(now.addingTimeInterval(-400 * day))) < 2 } == true)
        #expect(report.queued == 1 && report.atRisk == 1 && !report.coversRetention && report.deleteBefore == nil)

        // Once it is archived, coverage reaches the last listing and covers the retention cutoff.
        try await store.write(RawMessage(key: RawMessageKey(accountID: account, folder: "INBOX", uidValidity: 1, uid: 1),
                                         internalDate: now.addingTimeInterval(-400 * day), size: 10, bytes: try Fixtures.data("01-")))
        report = try Coverage.compute(test.archive, account: account, retentionMonths: 12, now: now)
        #expect(report.coverageDate.map { abs($0.timeIntervalSince(now)) < 2 } == true)
        #expect(report.coversRetention && report.atRisk == 0)
        #expect(report.safeToDelete == 1)
        #expect(report.deleteBefore.map { $0 < report.retentionCutoff! } == true)
        #expect(try test.count("accounts", "coverage_date IS NOT NULL") == 1)
    }

    @Test func accountsLiveInTheArchiveAndRemovalKeepsMail() async throws {
        let test = try await imported()
        defer { test.remove() }
        let accounts = ArchiveAccounts(archive: test.archive)
        let record = try #require(try accounts.record(test.account.id))
        #expect(record.isConnected && !record.needsSignIn)
        #expect(throws: AccountDirectoryError.self) { try accounts.add(AccountRecord(account: test.account)) }
        try accounts.setNeedsSignIn(test.account.id, true)
        #expect(try accounts.find("sam@example.com").needsSignIn)
        try accounts.disconnect(test.account.id)
        #expect(try accounts.connected().isEmpty)
        #expect(try accounts.disconnected(provider: .microsoft, email: "SAM@example.com")?.account.id == test.account.id)
        #expect(try test.count("messages") == 25) // mail kept
        try accounts.reconnect(test.account.id)
        #expect(try accounts.connected().count == 1)

        // Phase 1 Keychain records keep their IDs when moved in.
        let phase1 = AccountRecord(account: Account(id: .generate(), provider: .gmail, email: "old@example.com", displayName: "Old"))
        #expect(try accounts.adopt([phase1, phase1]) == [phase1.account.id, phase1.account.id])
        #expect(try accounts.record(phase1.account.id)?.account.email == "old@example.com")
    }
}

@Suite(.serialized) struct LocationTests {
    @Test func temporaryFoldersAreOnASuitableLocalDisk() {
        let volume = ArchiveLocation.checkVolume(FileManager.default.temporaryDirectory.appendingPathComponent("not-yet"))
        #expect(volume.isLocal)
        #expect(volume.fileSystem == "apfs")
        #expect(volume.verdict == .suitable)
    }

    @Test func cloudFoldersAreRefusedByTheVolumeCheck() {
        let icloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/x")
        guard case .refused = ArchiveLocation.checkVolume(icloud).verdict else {
            Issue.record("iCloud Drive must be refused")
            return
        }
    }

    @Test func aChosenFolderIsRememberedAndAnAbsentArchiveIsOffline() throws {
        let defaults = try #require(UserDefaults(suiteName: "uk.getstow.tests.\(UUID().uuidString)"))
        let settings = ArchiveSettings(defaults: defaults)
        #expect(settings.chosenFolder == nil)
        let folder = URL(fileURLWithPath: "/Volumes/NotConnected/Stow", isDirectory: true)
        settings.setChosenFolder(folder)
        let location = ArchiveLocation.fromEnvironment([:], settings: settings)
        #expect(location.root.path == folder.path)
        #expect(throws: ArchiveLocationError.offline(folder.path)) { try location.requireOnline() }
        // The environment variable wins, for development and tests.
        #expect(ArchiveLocation.fromEnvironment(["STOW_ARCHIVE_DIR": "/tmp/x"], settings: settings).root.path.hasSuffix("/tmp/x"))
        settings.setChosenFolder(nil)
        #expect(ArchiveLocation.fromEnvironment([:], settings: settings) == ArchiveLocation.defaultForCLI)
    }

    @Test func oneWriterAtATime() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let first = try ArchiveLock.acquire(test.location)
        #expect(throws: ArchiveLockError.busy) { try ArchiveLock.acquire(test.location) }
        first.release()
        let second = try ArchiveLock.acquire(test.location, wait: 1)
        second.release()
    }

    @Test func movingCopiesVerifiesAndLeavesTheOriginal() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages().filter { $0.bytes.count < 1_000_000 }))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("stow-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(throws: ArchiveMoveError.destinationInsideArchive) {
            try ArchiveMover.check(test.location, destination: test.location.root.appendingPathComponent("inner"))
        }
        let report = try ArchiveMover.copy(test.archive, to: destination, keys: test.keys)
        #expect(report.isClean && report.messages == 24)
        let copy = try Archive.open(ArchiveLocation(root: destination), keys: test.keys)
        #expect(try copy.archiveID() == test.archive.archiveID())
        #expect(try test.count("messages") == 24) // the original is untouched
        // A folder that already has things in it is refused.
        #expect(throws: ArchiveMoveError.destinationNotEmpty(destination.standardizedFileURL.path)) {
            try ArchiveMover.check(test.location, destination: destination)
        }
    }
}
