import Foundation
import Logging
import StowCore
@testable import StowEngine
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

/// Keeps every line a logger was given, for the scheduler's notice lines (D-935).
final class RecordedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var all: [String] { lock.withLock { lines } }
    var notices: [String] { all.filter { $0.hasPrefix("notice ") } }

    func append(_ line: String) { lock.withLock { lines.append(line) } }

    func logger() -> Logger {
        Logger(label: "test") { _ in RecordingHandler(recorded: self) }
    }

    struct RecordingHandler: LogHandler {
        let recorded: RecordedLines
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            let merged = metadata.merging(event.metadata ?? [:]) { $1 }
            let fields = merged.keys.sorted().map { "\($0)=\(merged[$0]!)" }.joined(separator: " ")
            recorded.append("\(event.level) \(event.message) \(fields)")
        }
    }
}

extension SchedulerTests {
    /// D-935: a healthy sync leaves notice lines a support reader can follow (sync running,
    /// mail downloaded, first download finished), counts and the account ID only, and a
    /// quiet round adds nothing.
    @Test func aHealthySyncLeavesCountsOnlyNoticesAndAQuietRoundNone() async throws {
        let fixtures = try TestFixtures.small()
        let (archive, location, keys) = try confirmedArchive()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let server = microsoftServer(fixtures)
        let port = Int(try await server.start())
        defer { server.stop() }
        let account = Account(id: .generate(), provider: .microsoft, email: "sam@example.com", displayName: "Sam's mail")
        try ArchiveAccounts(archive: archive).add(AccountRecord(account: account))
        try archive.database.close()

        let recorded = RecordedLines()
        let scheduler = Scheduler(
            openArchive: { try Archive.open(location, keys: keys) },
            makeSync: { archive in
                EngineSync(archive: archive, settingsURL: location.root.appendingPathComponent("none.json"), sleep: { _ in }) { account in
                    {
                        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: port))
                        try await session.authenticate(user: account.email, accessToken: "good-token")
                        return session
                    }
                }
            },
            power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) },
            // One round, then stop.
            sleep: { _ in throw CancellationError() },
            logger: recorded.logger()
        )

        #expect(await scheduler.run() == .cancelled)
        let first = recorded.notices
        #expect(first.contains { $0.hasPrefix("notice Account synced account=\(account.id) bytes=") && $0.contains("downloaded=\(fixtures.count) ") })
        #expect(first.contains { $0 == "notice First download finished account=\(account.id) unfetchable=0" })
        #expect(first.contains { $0 == "notice Sync running accounts=1" })
        #expect(first.count == 3)

        // Caught up: another round downloads nothing and logs nothing at notice.
        let (result, _) = await scheduler.round()
        #expect(result == .idle)
        #expect(recorded.notices == first)

        // Never the address, the account's name or anything from the mail.
        for line in recorded.all {
            #expect(!line.contains("example.com"))
            #expect(!line.contains("Sam's mail"))
        }
    }

    /// D-935: the first successful turn after a failure is logged even when it downloads
    /// nothing, so the log shows the account recovered.
    @Test func aTurnAfterAFailureIsLoggedEvenWhenQuiet() async throws {
        let (archive, location, keys) = try confirmedArchive()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let server = microsoftServer([])
        server.acceptedTokens = ["good-token"]
        let port = Int(try await server.start())
        defer { server.stop() }
        let account = Account(id: .generate(), provider: .microsoft, email: "pat@example.com", displayName: "P")
        try ArchiveAccounts(archive: archive).add(AccountRecord(account: account))
        try archive.database.close()

        final class State: @unchecked Sendable {
            var now = Date()
            var token = "revoked"
        }
        let state = State()
        let recorded = RecordedLines()
        let scheduler = Scheduler(
            openArchive: { try Archive.open(location, keys: keys) },
            makeSync: { archive in
                EngineSync(archive: archive, settingsURL: location.root.appendingPathComponent("none.json"), sleep: { _ in }) { account in
                    {
                        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: port))
                        try await session.authenticate(user: account.email, accessToken: state.token)
                        return session
                    }
                }
            },
            power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) },
            now: { state.now },
            logger: recorded.logger()
        )
        guard case .failed? = await scheduler.round().1[account.id] else { Issue.record("should fail"); return }
        #expect(recorded.notices.isEmpty)

        state.token = "good-token"
        state.now = state.now.addingTimeInterval(301)
        guard case .synced(let report)? = await scheduler.round().1[account.id] else { Issue.record("should sync"); return }
        #expect(report.messagesWritten == 0)
        #expect(recorded.notices.contains { $0.hasPrefix("notice Account synced again after a failure account=\(account.id) ") })
        let before = recorded.notices.filter { $0.contains("Account synced") }.count

        // Quiet again: nothing more.
        state.now = state.now.addingTimeInterval(301)
        _ = await scheduler.round()
        #expect(recorded.notices.filter { $0.contains("Account synced") }.count == before)
    }

    /// D-936: the pause reason without a confirmed recovery key reaches the app's log,
    /// so it names no command-line command.
    @Test func theRecoveryPauseReasonNamesNoCommand() {
        #expect(!Scheduler.recoveryPauseReason.contains("stowmail"))
        #expect(Scheduler.recoveryPauseReason.contains("recovery key"))
    }

    @Test func aQuietTurnHasNoMessage() {
        #expect(Scheduler.turnMessage(SyncReport(), recovered: false) == nil)
        var report = SyncReport()
        report.messagesWritten = 2
        #expect(Scheduler.turnMessage(report, recovered: false) == "Account synced")
        #expect(Scheduler.turnMessage(SyncReport(), recovered: true) == "Account synced again after a failure")
    }
}
