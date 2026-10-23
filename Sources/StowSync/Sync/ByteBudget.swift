import Foundation
import StowCore

/// Counts bytes downloaded for one account over a rolling 24 hours, and says
/// whether more may be fetched (D-106). Kept in the archive's `byte_budget`
/// table from Phase 2, so the count survives restarts and is shared by every
/// process; a small JSON file (or memory) remains for tests and tools.
public actor ByteBudget {
    public static let window: TimeInterval = 24 * 60 * 60

    struct Entry: Codable, Equatable {
        var at: Date
        var bytes: Int64
    }

    private enum Backend {
        case local(fileURL: URL?)
        case syncState(SyncStateStore, AccountID)
    }

    public let limit: Int64?
    private let backend: Backend
    private let now: @Sendable () -> Date
    private var entries: [Entry]

    /// - Parameters:
    ///   - limit: bytes allowed per rolling 24 hours, or nil for no limit.
    ///   - fileURL: where to keep the count, or nil to keep it in memory only.
    public init(limit: Int64?, fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        backend = .local(fileURL: fileURL)
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    /// A budget kept by the sync state store (the archive) for `account`.
    public init(limit: Int64?, store: SyncStateStore, account: AccountID, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        backend = .syncState(store, account)
        self.now = now
        entries = []
    }

    /// Bytes downloaded in the last 24 hours.
    public func used() async throws -> Int64 {
        let cutoff = now().addingTimeInterval(-Self.window)
        switch backend {
        case .local:
            entries.removeAll { $0.at <= cutoff }
            return entries.reduce(0) { $0 + $1.bytes }
        case .syncState(let store, let account):
            return try await store.bytesDownloaded(account, since: cutoff)
        }
    }

    /// Whether `bytes` more may be downloaded now.
    public func allows(_ bytes: Int64) async throws -> Bool {
        guard let limit else { return true }
        return try await used() + bytes <= limit
    }

    public func record(_ bytes: Int64) async throws {
        guard bytes > 0 else { return }
        switch backend {
        case .local(let fileURL):
            let cutoff = now().addingTimeInterval(-Self.window)
            entries.removeAll { $0.at <= cutoff }
            entries.append(Entry(at: now(), bytes: bytes))
            try save(to: fileURL)
        case .syncState(let store, let account):
            try await store.recordDownload(account, bytes: bytes, at: now())
        }
    }

    private func save(to fileURL: URL?) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(entries).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
