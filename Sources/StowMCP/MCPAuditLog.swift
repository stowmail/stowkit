import Foundation
import StowCore

/// One line of the audit log: which tool was called, with what search terms,
/// and how many results went back. Never a subject, body, attachment text or
/// sender (D-081).
public struct MCPAuditEntry: Codable, Sendable, Equatable {
    public var at: Date
    /// The MCP client, as it named itself (for example "claude-ai 0.1.0").
    public var client: String?
    public var tool: String
    /// The call's arguments, with email addresses replaced (`Redact.scrub`).
    public var arguments: [String: String]
    /// The accounts the call could see (IDs, never addresses).
    public var accounts: [String]
    /// Messages, folders or characters returned, depending on the tool.
    public var results: Int
    public var error: Bool

    public init(at: Date = Date(), client: String?, tool: String, arguments: [String: String], accounts: [String],
                results: Int, error: Bool) {
        self.at = at
        self.client = client
        self.tool = tool
        self.arguments = arguments
        self.accounts = accounts
        self.results = results
        self.error = error
    }
}

extension MCPAuditEntry {
    /// The line `stowmail mcp log` prints for this entry, after `time`. The
    /// client name, tool and arguments come from an assistant, which an email
    /// can steer, so each goes through `ArchiveTools.oneLine`: no escape
    /// sequence, line break or bidi control reaches the terminal (A-16). The
    /// audit file itself keeps what was sent.
    public func printedLine(time: String) -> String {
        let clean = ArchiveTools.oneLine
        let arguments = self.arguments.sorted { $0.key < $1.key }.map { "\(clean($0.key))=\(clean($0.value))" }.joined(separator: " ")
        return "\(time)  \(clean(client ?? "unknown client"))  \(clean(tool))  \(arguments)  -> \(results)\(error ? " (error)" : "")"
    }
}

/// Records every tool call to `mcp-audit.log` beside Stow's other logs, one JSON
/// object per line (D-081). The folder is 0700 and the file 0600, as for the
/// main log (D-040). Rotated at 5 MB, one old file kept.
public actor MCPAuditLog {
    public static let fileName = "mcp-audit.log"
    static let rotateAt: UInt64 = 5 * 1024 * 1024

    public nonisolated let url: URL
    private let encoder: JSONEncoder

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func record(_ entry: MCPAuditEntry) throws {
        var entry = entry
        entry.arguments = entry.arguments.mapValues(Redact.scrub)
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))

        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let size = try? files.attributesOfItem(atPath: url.path)[.size] as? UInt64, size >= Self.rotateAt {
            let old = url.appendingPathExtension("1")
            try? files.removeItem(at: old)
            try files.moveItem(at: url, to: old)
        }
        if !files.fileExists(atPath: url.path) {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// The last `count` entries, oldest first, for `stowmail mcp log`.
    public func recent(_ count: Int) throws -> [MCPAuditEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).suffix(count).compactMap { try? decoder.decode(MCPAuditEntry.self, from: Data($0)) }
    }
}
