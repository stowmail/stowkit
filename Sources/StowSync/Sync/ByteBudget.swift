import Foundation

/// Counts bytes downloaded for one account over a rolling 24 hours, and says
/// whether more may be fetched (D-106). Saved to a small JSON file so the
/// count survives restarts. The file holds only times and byte counts.
public actor ByteBudget {
    public static let window: TimeInterval = 24 * 60 * 60

    struct Entry: Codable, Equatable {
        var at: Date
        var bytes: Int64
    }

    public let limit: Int64?
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var entries: [Entry]

    /// - Parameters:
    ///   - limit: bytes allowed per rolling 24 hours, or nil for no limit.
    ///   - fileURL: where to keep the count, or nil to keep it in memory only.
    public init(limit: Int64?, fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    /// Bytes downloaded in the last 24 hours.
    public func used() -> Int64 {
        prune()
        return entries.reduce(0) { $0 + $1.bytes }
    }

    /// Whether `bytes` more may be downloaded now.
    public func allows(_ bytes: Int64) -> Bool {
        guard let limit else { return true }
        return used() + bytes <= limit
    }

    public func record(_ bytes: Int64) throws {
        guard bytes > 0 else { return }
        prune()
        entries.append(Entry(at: now(), bytes: bytes))
        try save()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.window)
        entries.removeAll { $0.at <= cutoff }
    }

    private func save() throws {
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
