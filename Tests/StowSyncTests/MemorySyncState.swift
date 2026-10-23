import Foundation
import StowCore

/// A `SyncStateStore` held in memory, with the same queue rules as the
/// archive's (`ArchiveSyncStore`), so sync can be tested without storage.
/// One instance stands for one persisted database: keep it across runs to
/// simulate a restart.
actor MemorySyncState: SyncStateStore {
    struct Entry {
        var message: QueuedMessage
        var attempts = 0
        var lastRunID: String?
        var unfetchable = false
        var flags: [String] = []
    }

    struct Folder {
        var info: SyncFolder?
        var state: FolderSyncState?
        var queue: [UInt32: Entry] = [:]
        /// Archived copies at the current UIDVALIDITY: UID to flags.
        var stored: [UInt32: [String]] = [:]
        var labels: [UInt32: [String]] = [:]
        var error: String?
    }

    private(set) var folders: [String: Folder] = [:]
    private var order: [String] = []
    private var downloads: [(Date, Int64)] = []
    private(set) var events: [(kind: String, old: String?, new: String?)] = []
    private(set) var sourceStates: [Int64: SourceState] = [:]

    private func folder(_ name: String) -> Folder {
        folders[name] ?? Folder()
    }

    private func update(_ name: String, _ change: (inout Folder) -> Void) {
        if folders[name] == nil { order.append(name) }
        var value = folders[name] ?? Folder()
        change(&value)
        folders[name] = value
    }

    func recordFolders(_ account: AccountID, _ list: [SyncFolder]) {
        for info in list { update(info.name) { $0.info = info } }
    }

    func folderState(_ account: AccountID, folder name: String) -> FolderSyncState? {
        folder(name).state
    }

    func syncedFolders(_ account: AccountID) -> [String] {
        order.filter { folders[$0]?.state != nil }
    }

    func beginFolder(_ account: AccountID, folder name: String, uidValidity: UInt32, exists: Int) -> UInt32? {
        var old: UInt32?
        update(name) { folder in
            guard let state = folder.state else {
                folder.state = FolderSyncState(uidValidity: uidValidity)
                return
            }
            guard state.uidValidity != uidValidity else { return }
            old = state.uidValidity
            folder.state = FolderSyncState(uidValidity: uidValidity)
            folder.queue = [:]
            folder.stored = [:]
        }
        if let old { events.append(("uidvalidity_changed", String(old), String(uidValidity))) }
        return old
    }

    func enqueue(_ account: AccountID, folder name: String, uidValidity: UInt32, messages: [QueuedMessage], listedThrough: UInt32) -> Int {
        var queued = 0
        update(name) { folder in
            for message in messages where folder.stored[message.uid] == nil && folder.queue[message.uid] == nil {
                folder.queue[message.uid] = Entry(message: message)
                queued += 1
            }
            let previous = folder.state?.listedThroughUID ?? 0
            folder.state?.listedThroughUID = max(previous, listedThrough)
        }
        return queued
    }

    func nextDownloads(_ account: AccountID, runID: String, maxMessages: Int, maxBytes: Int) -> [QueuedMessage] {
        let eligible = order.flatMap { name in
            (folders[name]?.queue.values ?? [:].values).filter { !$0.unfetchable && $0.lastRunID != runID }.map { (name, $0.message) }
        }
        guard let best = eligible.min(by: { ($0.1.priority, order.firstIndex(of: $0.0)!, $0.1.uid) < ($1.1.priority, order.firstIndex(of: $1.0)!, $1.1.uid) })
        else { return [] }
        let candidates = eligible.filter { $0.0 == best.0 && $0.1.priority == best.1.priority }.map(\.1).sorted { $0.uid < $1.uid }
        var batch: [QueuedMessage] = []
        var bytes = 0
        for message in candidates.prefix(max(1, maxMessages)) {
            if !batch.isEmpty, bytes + message.size > maxBytes { break }
            batch.append(message)
            bytes += message.size
        }
        return batch
    }

    func downloaded(_ account: AccountID, folder name: String, uidValidity: UInt32, uids: [UInt32]) {
        update(name) { folder in
            for uid in uids {
                folder.queue[uid] = nil
                folder.stored[uid] = folder.stored[uid] ?? []
            }
        }
    }

    func vanishedBeforeDownload(_ account: AccountID, folder name: String, uidValidity: UInt32, uids: [UInt32]) {
        update(name) { folder in for uid in uids { folder.queue[uid] = nil } }
    }

    func recordFailedAttempt(_ account: AccountID, folder name: String, uidValidity: UInt32, runID: String,
                             failed: [FailedDownload], threshold: Int) -> Set<UInt32> {
        var recorded: Set<UInt32> = []
        update(name) { folder in
            for failure in failed {
                guard var entry = folder.queue[failure.uid] else { continue }
                if entry.lastRunID != runID { entry.attempts += 1 }
                entry.lastRunID = runID
                entry.flags = failure.flags
                if entry.attempts >= threshold {
                    entry.unfetchable = true
                    recorded.insert(failure.uid)
                }
                folder.queue[failure.uid] = entry
            }
        }
        return recorded
    }

    func queueTotals(_ account: AccountID) -> QueueTotals {
        let entries = folders.values.flatMap(\.queue.values)
        let queued = entries.filter { !$0.unfetchable }
        return QueueTotals(queued: queued.count, queuedBytes: Int64(queued.reduce(0) { $0 + $1.message.size }),
                           unfetchable: entries.count - queued.count)
    }

    func queuedUIDs(_ account: AccountID, folder name: String, uidValidity: UInt32) -> [UInt32] {
        folder(name).queue.keys.sorted()
    }

    func folderWalked(_ account: AccountID, folder name: String, uidValidity: UInt32, at: Date) {
        update(name) { folder in
            if !folder.queue.values.contains(where: { !$0.unfetchable }), folder.state?.firstSyncCompletedAt == nil {
                folder.state?.firstSyncCompletedAt = at
            }
            folder.error = nil
        }
    }

    func storedUIDs(_ account: AccountID, folder name: String, uidValidity: UInt32) -> [UInt32] {
        folder(name).stored.keys.sorted()
    }

    func applyCopyStates(_ account: AccountID, folder name: String, uidValidity: UInt32, _ states: [CopyState], at: Date) {
        update(name) { folder in
            for state in states where folder.stored[state.uid] != nil {
                folder.stored[state.uid] = state.flags
                if let labels = state.labels { folder.labels[state.uid] = labels }
            }
        }
    }

    /// Message IDs here are UIDs: the memory store keeps no message rows.
    func markRemovedFromServer(_ account: AccountID, folder name: String, uidValidity: UInt32, uids: [UInt32], at: Date) -> [VanishedMessage] {
        var vanished: [VanishedMessage] = []
        update(name) { folder in
            for uid in uids where folder.stored.removeValue(forKey: uid) != nil {
                vanished.append(VanishedMessage(messageID: Int64(uid)))
            }
        }
        return vanished
    }

    func setSourceStates(_ account: AccountID, _ states: [Int64: SourceState], at: Date) {
        sourceStates.merge(states) { _, new in new }
    }

    func folderChecked(_ account: AccountID, folder name: String, uidValidity: UInt32, highestModSeq: UInt64?, fullCheck: Bool, at: Date) {
        update(name) { folder in
            if let highestModSeq { folder.state?.highestModSeq = highestModSeq }
            if fullCheck { folder.state?.lastFullCheckAt = at }
        }
    }

    func bytesDownloaded(_ account: AccountID, since: Date) -> Int64 {
        downloads.filter { $0.0 > since }.reduce(0) { $0 + $1.1 }
    }

    func recordDownload(_ account: AccountID, bytes: Int64, at: Date) {
        downloads.append((at, bytes))
    }

    func recordEvent(_ account: AccountID, folder: String?, kind: String, old: String?, new: String?, at: Date) {
        events.append((kind, old, new))
    }

    func setFolderError(_ account: AccountID, folder name: String, error: String?) {
        update(name) { $0.error = error }
    }

    // MARK: For tests

    func flags(_ folder: String, uid: UInt32) -> [String]? { folders[folder]?.stored[uid] }
    func labels(_ folder: String, uid: UInt32) -> [String]? { folders[folder]?.labels[uid] }
    func entry(_ folder: String, uid: UInt32) -> Entry? { folders[folder]?.queue[uid] }
}
