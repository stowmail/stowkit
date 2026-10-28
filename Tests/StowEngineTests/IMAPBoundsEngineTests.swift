import Foundation
import StowCore
import StowEngine
import StowStore
@testable import StowSync
import StowTestSupport
import Testing

/// A-13 (security sweep 1) at the level of a whole run: the full flag check
/// asks in windows, and one stuck account does not hold up the round (D-496).
@Suite(.serialized, .timeLimit(.minutes(1))) struct IMAPBoundsEngineTests {
    @Test func fullFlagCheckAsksInWindows() async throws {
        let server = gmailServer(try TestFixtures.small())
        let harness = try await EngineHarness(server: server)
        defer { harness.cleanUp() }
        let options = SyncOptions(listWindow: 10, checkChanges: .full)
        _ = try await harness.run(options)
        let before = server.commandLog.count
        _ = try await harness.run(options)
        let stateFetches = server.commandLog.dropFirst(before).filter {
            $0.contains("UID FETCH") && $0.contains("FLAGS") && !$0.contains("RFC822.SIZE") && !$0.contains("BODY")
        }
        #expect(!stateFetches.isEmpty)
        for line in stateFetches {
            let set = line.split(separator: " ")[3].split(separator: ":").compactMap { UInt32($0) }
            #expect(set.count == 2 && set[1] - set[0] < 10, "one command asked for \(line)")
        }
    }

    @Test func oneStuckAccountDoesNotHoldUpTheOthers() async throws {
        let (archive, location, keys) = try SchedulerTests().confirmedArchive()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let fixtures = try TestFixtures.small().prefix(3).map { $0 }
        let stuck = gmailServer(fixtures)
        let good = gmailServer(fixtures)
        stuck.trickleInterval = 0.2
        let ports = ["Stuck": Int(try await stuck.start()), "Good": Int(try await good.start())]
        defer { stuck.stop(); good.stop() }
        let accounts = ArchiveAccounts(archive: archive)
        let stuckAccount = Account(id: .generate(), provider: .gmail, email: "pat@example.com", displayName: "Stuck")
        let goodAccount = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Good")
        try accounts.add(AccountRecord(account: stuckAccount))
        try accounts.add(AccountRecord(account: goodAccount))

        let scheduler = Scheduler(
            settings: SchedulerSettings(turn: 1), // past the turn, a failed command is not retried within it
            openArchive: { try Archive.open(location, keys: keys) },
            makeSync: { archive in
                EngineSync(archive: archive, settingsURL: location.root.appendingPathComponent("none.json"), sleep: { _ in }) { account in
                    {
                        let session = try await IMAPSession.connect(to: .plaintextLoopback(port: ports[account.displayName]!),
                                                                    timeouts: IMAPTimeouts(connect: 5, read: 90, command: 2))
                        try await session.authenticate(user: account.email, accessToken: "good-token")
                        return session
                    }
                }
            },
            power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) }
        )
        let clock = ContinuousClock()
        let start = clock.now
        let (_, outcomes) = await scheduler.round()
        #expect(clock.now - start < .seconds(10))
        guard case .failed(let text)? = outcomes[stuckAccount.id] else {
            Issue.record("the stuck account should fail at the deadline, got \(String(describing: outcomes[stuckAccount.id]))")
            return
        }
        #expect(text.contains("took longer than"))
        guard case .synced? = outcomes[goodAccount.id] else {
            Issue.record("the other account should sync in the same round")
            return
        }
    }
}
