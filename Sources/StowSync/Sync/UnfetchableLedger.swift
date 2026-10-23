import Foundation
import StowCore

/// Messages a server lists but will not return, remembered across runs (D-115).
///
/// Exchange lists some non-mail items (for example deleted calendar entries in
/// Deleted Items) as messages but returns nothing for them. Each run that finds
/// such a UID still listed after a confirming re-fetch counts one attempt.
/// After `threshold` separate runs the UID is *recorded*: sync moves past it
/// and says so. Until then the folder stops before it (D-113).
///
/// Saved as JSON in the sync state folder, outside the raw store. It holds UIDs,
/// sizes, dates, flags and the folder name, never message content.
public actor UnfetchableLedger {
    public static let defaultThreshold = 3

    public struct Entry: Codable, Sendable, Equatable {
        public var uid: UInt32
        public var firstSeen: Date
        public var lastSeen: Date
        /// Separate runs in which it was listed but not returned.
        public var attempts: Int
        public var size: Int
        public var internalDate: Date?
        public var flags: [String]
        /// Set once `attempts` reaches the threshold: sync has moved past it.
        public var recordedAt: Date?
        var lastRunID: String
    }

    struct FolderEntries: Codable {
        var uidValidity: UInt32
        var entries: [UInt32: Entry]
    }

    public let threshold: Int
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var folders: [String: FolderEntries]

    public init(fileURL: URL?, threshold: Int = defaultThreshold, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.threshold = max(1, threshold)
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? Self.decoder.decode([String: FolderEntries].self, from: data) {
            folders = saved
        } else {
            folders = [:]
        }
    }

    /// Counts one attempt (at most once per run) for each stuck message and
    /// returns the UIDs that have now reached the threshold, so sync may pass them.
    public func recordAttempt(folder: String, uidValidity: UInt32, runID: String, stuck: [MessageSummary]) throws -> Set<UInt32> {
        var entries = current(folder: folder, uidValidity: uidValidity)
        var passable: Set<UInt32> = []
        let time = now()
        for summary in stuck {
            var entry = entries[summary.uid] ?? Entry(
                uid: summary.uid, firstSeen: time, lastSeen: time, attempts: 0, size: summary.size,
                internalDate: summary.internalDate, flags: summary.flags, recordedAt: nil, lastRunID: ""
            )
            if entry.lastRunID != runID {
                entry.attempts += 1
                entry.lastRunID = runID
                entry.lastSeen = time
            }
            if entry.attempts >= threshold {
                if entry.recordedAt == nil { entry.recordedAt = time }
                passable.insert(summary.uid)
            }
            entries[summary.uid] = entry
        }
        folders[folder] = FolderEntries(uidValidity: uidValidity, entries: entries)
        try save()
        return passable
    }

    /// Forgets UIDs that turned out fetchable or have gone from the server.
    public func resolve(folder: String, uidValidity: UInt32, uids: Set<UInt32>) throws {
        guard var saved = folders[folder], saved.uidValidity == uidValidity else { return }
        let before = saved.entries.count
        for uid in uids { saved.entries[uid] = nil }
        guard saved.entries.count != before else { return }
        folders[folder] = saved.entries.isEmpty ? nil : saved
        try save()
    }

    public func entries(folder: String) -> [Entry] {
        (folders[folder]?.entries.values).map { $0.sorted { $0.uid < $1.uid } } ?? []
    }

    /// Recorded (passed) and pending (still blocking) counts across all folders.
    public func totals() -> (recorded: Int, pending: Int) {
        let all = folders.values.flatMap(\.entries.values)
        let recorded = all.filter { $0.recordedAt != nil }.count
        return (recorded, all.count - recorded)
    }

    private func current(folder: String, uidValidity: UInt32) -> [UInt32: Entry] {
        guard let saved = folders[folder], saved.uidValidity == uidValidity else { return [:] } // UIDs renumbered: start over
        return saved.entries
    }

    private func save() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(folders).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The ledger file for an account in the sync state folder.
    public static func fileURL(stateDirectory: URL, accountID: AccountID) -> URL {
        stateDirectory.appendingPathComponent("\(accountID).unfetchable.json")
    }
}
