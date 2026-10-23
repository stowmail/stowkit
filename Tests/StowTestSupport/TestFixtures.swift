import Foundation

/// Synthetic `.eml` fixtures made by scripts/make-fixtures (D-018), for any test target.
public enum TestFixtures {
    public static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/eml", isDirectory: true)

    /// Every fixture, sorted by file name.
    public static func all() throws -> [(name: String, bytes: Data)] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "eml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
    }

    /// Fixtures without the 15 MiB one, for tests that do not need it.
    public static func small() throws -> [(name: String, bytes: Data)] {
        try all().filter { $0.bytes.count < 1_000_000 }
    }

    /// The fixture whose file name starts with `prefix`, for example "06-".
    public static func data(_ prefix: String) throws -> Data {
        guard let match = try all().first(where: { $0.name.hasPrefix(prefix) }) else { throw CocoaError(.fileNoSuchFile) }
        return match.bytes
    }

    /// A unique temporary folder (not created).
    public static func temporaryDirectory(_ suffix: String = "") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stow-test-\(UUID().uuidString)\(suffix)", isDirectory: true)
    }
}

/// A sleeper that never really waits, recording what it was asked for.
public final class RecordedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []

    public init() {}

    public var delays: [TimeInterval] { lock.withLock { _delays } }

    public func sleep(_ delay: TimeInterval) async throws {
        lock.withLock { _delays.append(delay) }
    }
}

/// Commands that change a mailbox. None may ever reach a server.
public let mailboxWriteVerbs = ["SELECT", "STORE", "EXPUNGE", "MOVE", "COPY", "APPEND", "DELETE", "CREATE", "RENAME",
                                "SUBSCRIBE", "UNSUBSCRIBE", "CLOSE", "SETMETADATA", "SETQUOTA"]

/// Lines of a fake server's command log that would change a mailbox or set \Seen. Empty means read-only.
public func readOnlyViolations(_ log: [String]) -> [String] {
    log.filter { line in
        let upper = line.uppercased()
        let words = upper.split(separator: " ").dropFirst().prefix(2).map(String.init)
        if mailboxWriteVerbs.contains(where: words.contains) { return true }
        return upper.contains("FETCH") && (upper.contains("BODY[]") || upper.contains("RFC822 ") || upper.contains("RFC822)")
            || (upper.contains("BODY[") && !upper.contains("BODY.PEEK[")))
    }
}
