import Foundation
import Logging
import StowCore
import Testing
@testable import StowSync

/// Collects every log line written in this test process.
final class CapturedLogs: @unchecked Sendable {
    static let shared = CapturedLogs()
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }

    /// Installs the capturing handler once for the whole test process, at trace level.
    static let installed: Bool = {
        LoggingSystem.bootstrap { label in CaptureHandler(label: label) }
        return true
    }()
}

struct CaptureHandler: LogHandler {
    let label: String
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        let merged = self.metadata.merging(metadata ?? [:]) { $1 }
        CapturedLogs.shared.append("\(level) \(label) \(message) \(merged)")
    }
}

/// Security checklist: no tokens and no message content in logs.
@Suite struct LoggingTests {
    @Test func syncLogsNoTokensAddressesOrContent() async throws {
        _ = CapturedLogs.installed
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures)
        server.dropOnBodyFetchNumber = 2 // exercise the retry and error paths too
        server.acceptedTokens = ["secret-access-token-XYZ"]
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }
        _ = try await harness.syncer(token: "secret-access-token-XYZ").run(SyncOptions(batches: BatchPlanner(maxMessages: 5)))

        // A refused token also goes through the logs.
        _ = try? await harness.syncer(token: "refused-token-ABC").run()

        let logs = CapturedLogs.shared.all.joined(separator: "\n")
        #expect(logs.contains("IMAP command")) // the handler really captured sync logs
        for secret in ["secret-access-token-XYZ", "refused-token-ABC", "sam@example.com", "LANTERN-COAST-1150", "Walk on Saturday", "Tous les messages"] {
            #expect(!logs.contains(secret), "log contains \(secret)")
        }
        // The XOAUTH2 string, base64-encoded, never appears either.
        let xoauth = Data(XOAUTH2.initialResponse(user: "sam@example.com", accessToken: "secret-access-token-XYZ")).base64EncodedString()
        #expect(!logs.contains(xoauth))

        // The stored metadata files hold no token either.
        for url in FileManager.default.enumerator(at: harness.root, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL })
        where url.pathExtension == "json" {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("secret-access-token-XYZ"))
        }
    }
}
