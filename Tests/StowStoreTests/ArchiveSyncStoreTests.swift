import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// The archive as sync's sink and state (D-027, D-038, D-039).
@Suite(.serialized) struct ArchiveSyncStoreTests {
    let inbox = "INBOX"

    func setUp() throws -> (TestArchive, ArchiveSyncStore) {
        let test = try TestArchive()
        let store = ArchiveSyncStore(archive: test.archive)
        return (test, store)
    }

    func queued(_ uid: UInt32, priority: Int = 0, size: Int = 100, folder: String = "INBOX", gmail: UInt64? = nil) -> QueuedMessage {
        QueuedMessage(folder: folder, uidValidity: 1, uid: uid, size: size, internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
                      priority: priority, gmailMessageID: gmail)
    }

    @Test func queueGivesTheBestPriorityFirstAndOneFolderAtATime() async throws {
        let (test, store) = try setUp()
        defer { test.remove() }
        let account = test.account.id
        try await store.recordFolders(account, [SyncFolder(name: inbox), SyncFolder(name: "Sent")])
        _ = try await store.beginFolder(account, folder: inbox, uidValidity: 1, exists: 4)
        _ = try await store.beginFolder(account, folder: "Sent", uidValidity: 1, exists: 1)
        try await store.enqueue(account, folder: inbox, uidValidity: 1,
                                messages: [queued(1, priority: 2), queued(2), queued(3, priority: 1), queued(4)], listedThrough: 4)
        try await store.enqueue(account, folder: "Sent", uidValidity: 1, messages: [queued(1, folder: "Sent")], listedThrough: 1)
        #expect(try await store.folderState(account, folder: inbox)?.listedThroughUID == 4)

        let first = try await store.nextDownloads(account, runID: "r", maxMessages: 10, maxBytes: 10_000)
        #expect(first.map(\.uid) == [2, 4] && first.allSatisfy { $0.folder == inbox })
        try await store.downloaded(account, folder: inbox, uidValidity: 1, uids: [2, 4])
        let second = try await store.nextDownloads(account, runID: "r", maxMessages: 10, maxBytes: 10_000)
        #expect(second.map(\.folder) == ["Sent"]) // personal mail in every folder before bulk mail anywhere
        try await store.downloaded(account, folder: "Sent", uidValidity: 1, uids: [1])
        #expect(try await store.nextDownloads(account, runID: "r", maxMessages: 10, maxBytes: 10_000).map(\.uid) == [3])
        // The byte cap, but never an empty batch.
        #expect(try await store.nextDownloads(account, runID: "r", maxMessages: 10, maxBytes: 1).count == 1)
        #expect(try await store.queueTotals(account) == QueueTotals(queued: 2, queuedBytes: 200, unfetchable: 0))
    }

    @Test func archivedAndRemovedMessagesAreNotQueuedAgain() async throws {
        let (test, store) = try setUp()
        defer { test.remove() }
        let account = test.account.id
        _ = try await store.beginFolder(account, folder: inbox, uidValidity: 1, exists: 3)
        try await store.write(test.raw(try Fixtures.data("01-"), uid: 1))
        #expect(try await store.enqueue(account, folder: inbox, uidValidity: 1, messages: [queued(1), queued(2)], listedThrough: 2) == 1)
        #expect(try await store.storedUIDs(account, folder: inbox, uidValidity: 1) == [1])
        #expect(try await store.queuedUIDs(account, folder: inbox, uidValidity: 1) == [2])
    }

    @Test func writingAMessageTakesItOffTheQueueInTheSameStep() async throws {
        let (test, store) = try setUp()
        defer { test.remove() }
        let account = test.account.id
        _ = try await store.beginFolder(account, folder: inbox, uidValidity: 1, exists: 1)
        try await store.enqueue(account, folder: inbox, uidValidity: 1, messages: [queued(5)], listedThrough: 5)
        try await store.write(test.raw(try Fixtures.data("02-"), uid: 5))
        #expect(try await store.queuedUIDs(account, folder: inbox, uidValidity: 1).isEmpty)
        // Writing the same copy again is harmless.
        try await store.write(test.raw(try Fixtures.data("02-"), uid: 5))
        #expect(try test.count("messages") == 1)
    }

    @Test func failedAttemptsCountOncePerRunAndAreRecordedAtTheThreshold() async throws {
        let (test, store) = try setUp()
        defer { test.remove() }
        let account = test.account.id
        _ = try await store.beginFolder(account, folder: inbox, uidValidity: 1, exists: 1)
        try await store.enqueue(account, folder: inbox, uidValidity: 1, messages: [queued(9)], listedThrough: 9)
        let failure = [FailedDownload(uid: 9, flags: ["\\Seen"])]
        #expect(try await store.recordFailedAttempt(account, folder: inbox, uidValidity: 1, runID: "a", failed: failure, threshold: 3).isEmpty)
        #expect(try await store.recordFailedAttempt(account, folder: inbox, uidValidity: 1, runID: "a", failed: failure, threshold: 3).isEmpty)
        // Failed in run "a": not offered again in that run, but offered to the next.
        #expect(try await store.nextDownloads(account, runID: "a", maxMessages: 5, maxBytes: 1000).isEmpty)
        #expect(try await store.nextDownloads(account, runID: "b", maxMessages: 5, maxBytes: 1000).count == 1)
        #expect(try await store.recordFailedAttempt(account, folder: inbox, uidValidity: 1, runID: "b", failed: failure, threshold: 3).isEmpty)
        #expect(try await store.recordFailedAttempt(account, folder: inbox, uidValidity: 1, runID: "c", failed: failure, threshold: 3) == [9])
        #expect(try await store.queueTotals(account) == QueueTotals(queued: 0, queuedBytes: 0, unfetchable: 1))
        #expect(try test.count("download_queue", "attempts = 3 AND flags = '\\Seen' AND recorded_at IS NOT NULL") == 1)
        #expect(try test.count("sync_events", "kind = 'unfetchable_recorded'") == 1)
        // Recorded messages do not hold up the folder's first sync.
        try await store.folderWalked(account, folder: inbox, uidValidity: 1, at: Date())
        #expect(try await store.folderState(account, folder: inbox)?.firstSyncCompletedAt != nil)
    }

    @Test func aUIDVALIDITYChangeForgetsTheQueueAndRetiresCopiesNotFoundAgain() async throws {
        let (test, store) = try setUp()
        defer { test.remove() }
        let account = test.account.id
        _ = try await store.beginFolder(account, folder: inbox, uidValidity: 1, exists: 2)
        try await store.write(test.raw(try Fixtures.data("01-"), uid: 1))
        try await store.write(test.raw(try Fixtures.data("02-"), uid: 2))
        try await store.enqueue(account, folder: inbox, uidValidity: 1, messages: [queued(3)], listedThrough: 3)

        #expect(try await store.beginFolder(account, folder: inbox, uidValidity: 2, exists: 1) == 1)
        #expect(try await store.folderState(account, folder: inbox) == FolderSyncState(uidValidity: 2))
        #expect(try test.count("download_queue") == 0)
        #expect(try test.count("sync_events", "kind = 'uidvalidity_changed' AND old_value = '1' AND new_value = '2'") == 1)
        // The new walk finds the first message again at a new UID: its copy moves there.
        let moved = RawMessage(key: RawMessageKey(accountID: account, folder: inbox, uidValidity: 2, uid: 7),
                               internalDate: Date(), size: 1, bytes: try Fixtures.data("01-"))
        try await store.write(moved)
        try await store.folderWalked(account, folder: inbox, uidValidity: 2, at: Date())
        #expect(try test.count("message_folders", "uid_validity = 2 AND uid = 7 AND removed_from_server_at IS NULL") == 1)
        // The second was not found again: its copy is retired, and it is gone (but kept).
        #expect(try test.count("message_folders", "uid_validity = 1 AND removed_from_server_at IS NOT NULL") == 1)
        #expect(try test.count("messages", "source_state = 'gone'") == 1)
        #expect(try test.count("messages") == 2)
    }

    @Test func gmailMessagesAlreadyArchivedAreRelinkedWithoutDownload() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = ArchiveSyncStore(archive: test.archive)
        let account = test.account.id
        let allMail = "[Gmail]/All Mail"
        _ = try await store.beginFolder(account, folder: allMail, uidValidity: 1, exists: 1)
        var raw = test.raw(try Fixtures.data("01-"), folder: allMail, uid: 1)
        raw.gmailMessageID = 4242
        try await store.write(raw)
        _ = try await store.beginFolder(account, folder: allMail, uidValidity: 5, exists: 1)
        let queuedCount = try await store.enqueue(account, folder: allMail, uidValidity: 5,
                                                  messages: [queued(30, folder: allMail, gmail: 4242)], listedThrough: 30)
        #expect(queuedCount == 0)
        #expect(try test.count("message_folders", "uid_validity = 5 AND uid = 30") == 1)
    }

    @Test func presenceDecidesWhatVanishedMessagesBecome() async throws {
        let (test, store) = try setUp()
        defer { test.remove() }
        let account = test.account.id
        try await store.recordFolders(account, [SyncFolder(name: inbox), SyncFolder(name: "Archive"),
                                               SyncFolder(name: "Deleted Items", specialUse: "\\trash")])
        for folder in [inbox, "Archive", "Deleted Items"] { _ = try await store.beginFolder(account, folder: folder, uidValidity: 1, exists: 3) }
        let moved = try Fixtures.data("01-"), trashed = try Fixtures.data("02-"), gone = try Fixtures.data("03-")
        for (uid, data) in [(1, moved), (2, trashed), (3, gone)] { try await store.write(test.raw(data, uid: UInt32(uid))) }
        try await store.write(test.raw(moved, folder: "Archive", uid: 1))
        try await store.write(test.raw(trashed, folder: "Deleted Items", uid: 1))

        let vanished = try await store.markRemovedFromServer(account, folder: inbox, uidValidity: 1, uids: [1, 2, 3], at: Date())
        #expect(vanished.count == 1) // only the one with no copy left anywhere needs looking up
        #expect(vanished.first?.rfc822MessageID != nil)
        #expect(try test.count("messages", "source_state = 'present'") == 2)
        #expect(try test.count("messages", "source_state = 'trashed'") == 1)
        try await store.setSourceStates(account, [vanished[0].messageID: .spam], at: Date())
        #expect(try test.count("messages", "source_state = 'spam' AND source_state_at IS NOT NULL") == 1)
        // Nothing was deleted from the archive.
        #expect(try test.count("messages") == 3)
    }

    @Test func flagsAndLabelsFollowTheServer() async throws {
        let (test, store) = try setUp()
        defer { test.remove() }
        let account = test.account.id
        let allMail = "[Gmail]/All Mail"
        _ = try await store.beginFolder(account, folder: allMail, uidValidity: 1, exists: 1)
        var raw = test.raw(try Fixtures.data("01-"), folder: allMail, uid: 1, labels: ["\\Inbox", "Walks"])
        raw.flags = ["\\Seen"]
        try await store.write(raw)
        #expect(try test.count("message_folders", "flags = '\\Seen'") == 1)
        try await store.applyCopyStates(account, folder: allMail, uidValidity: 1,
                                        [CopyState(uid: 1, flags: ["\\Flagged", "\\Seen"], labels: ["Walks", "Receipts"])], at: Date())
        #expect(try test.count("message_folders", "flags = '\\Flagged \\Seen'") == 1)
        let labels = try await test.archive.database.read { db in
            try String.fetchAll(db, sql: """
                SELECT f.name FROM message_folders mf JOIN folders f ON f.id = mf.folder_id
                WHERE f.kind = 'label' AND mf.removed_from_server_at IS NULL ORDER BY f.name
                """)
        }
        #expect(labels == ["Receipts", "Walks"])
    }

    @Test func budgetIsSharedThroughTheArchive() async throws {
        let (test, store) = try setUp()
        defer { test.remove() }
        let account = test.account.id
        let now = Date()
        try await store.recordDownload(account, bytes: 500, at: now.addingTimeInterval(-90_000))
        try await store.recordDownload(account, bytes: 300, at: now)
        #expect(try await store.bytesDownloaded(account, since: now.addingTimeInterval(-86_400)) == 300)
    }
}
