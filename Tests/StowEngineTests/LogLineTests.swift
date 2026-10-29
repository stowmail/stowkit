import Foundation
import Logging
@testable import StowEngine
import StowTestSupport
import Testing

/// A-15: server text cannot start a new log line, metadata keys are scrubbed,
/// and the log folder and file are private even if they existed with looser modes.
@Suite struct LogLineTests {
    func logged(_ message: Logger.Message, metadata: Logger.Metadata) throws -> String {
        let folder = TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stowmail.log")
        let handler = FileLogHandler(label: "test", file: LogFile(url: url), level: .debug)
        Logger(label: "test") { _ in handler }.warning(message, metadata: metadata)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let breakers = ["\r", "\n", "\r\n", "\u{2028}", "\u{2029}", "\u{85}", "\u{1B}", "\u{0}", "\u{7}", "\u{7F}", "\u{9B}", "\u{202E}"]

    @Test(arguments: breakers)
    func oneEventIsOneLine(breaker: String) throws {
        let text = try logged("server said\(breaker)2026-10-29T00:00:00Z notice forged: line",
                              metadata: ["detail": "x\(breaker)y", "key\(breaker)k": "v"])
        #expect(text.hasSuffix("\n"))
        let body = text.dropLast()
        #expect(!body.unicodeScalars.contains { Character($0).isNewline }, "a line break survived")
        #expect(!body.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == "\u{202E}" })
        #expect(body.contains("server said\\"))
    }

    @Test func escapesAreReadable() throws {
        let text = try logged("a\r\nb\u{1B}[2Kc", metadata: [:])
        #expect(text.contains(#"a\r\nb\u{1B}[2Kc"#))
    }

    @Test func metadataKeysAreScrubbed() throws {
        let text = try logged("ok", metadata: ["sam@example.com": "1", "Bearer abcdefghijklmnopqrstuvwxyz0123456789ABCD": "2"])
        #expect(!text.contains("sam@example.com"))
        #expect(!text.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
    }

    @Test func standardErrorUsesTheSameLine() {
        let event = LogEvent(level: .warning, message: "a\nb", metadata: ["k\nk": "v\r"], source: "s", file: "f", function: "fn", line: 1)
        let line = FileLogHandler.line(event, label: "test", metadata: [:])
        #expect(line.filter { $0 == "\n" }.count == 1)
    }

    @Test func anExistingLooseFolderAndFileAreTightened() throws {
        let folder = TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let url = folder.appendingPathComponent("stowmail.log")
        FileManager.default.createFile(atPath: url.path, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644])
        let handler = FileLogHandler(label: "test", file: LogFile(url: url), level: .debug)
        Logger(label: "test") { _ in handler }.notice("first")
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("old\n"))
    }
}
