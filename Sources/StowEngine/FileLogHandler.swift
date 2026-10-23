import Foundation
import Logging
import StowCore

/// Writes log lines to `~/Library/Logs/Stow/stowmail.log` (step 8, D-040).
///
/// Every message and metadata value passes through `Redact.scrub` here, as a
/// last line of defence: code already never logs tokens or content (D-014), and
/// this catches anything that slips through, such as a server error quoting an
/// address. The file is 0600 in a 0700 folder, and is rotated at 10 MB,
/// keeping three old files.
public struct FileLogHandler: LogHandler {
    public var logLevel: Logger.Level
    public var metadata: Logger.Metadata = [:]
    let label: String
    let file: LogFile

    public init(label: String, file: LogFile = .shared, level: Logger.Level = .notice) {
        self.label = label
        self.file = file
        logLevel = level
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        let details = merged.isEmpty ? "" : " " + merged.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Redact.scrub($0.value.description))" }.joined(separator: " ")
        file.append("\(Self.timestamp()) \(event.level) \(label): \(Redact.scrub(event.message.description))\(details)\n")
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

/// One log file shared by every handler in the process.
public final class LogFile: @unchecked Sendable {
    public static let shared = LogFile(url: LaunchAgent.logDirectory.appendingPathComponent("stowmail.log"))
    static let maximumSize = 10 << 20
    static let keep = 3

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    func append(_ line: String) {
        lock.withLock {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maximumSize {
                rotate()
            }
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// stowmail.log becomes stowmail.log.1, .1 becomes .2, and so on; the oldest goes.
    private func rotate() {
        let manager = FileManager.default
        try? manager.removeItem(at: URL(fileURLWithPath: url.path + ".\(Self.keep)"))
        for index in stride(from: Self.keep - 1, through: 1, by: -1) {
            try? manager.moveItem(at: URL(fileURLWithPath: url.path + ".\(index)"), to: URL(fileURLWithPath: url.path + ".\(index + 1)"))
        }
        try? manager.moveItem(at: url, to: URL(fileURLWithPath: url.path + ".1"))
    }
}
