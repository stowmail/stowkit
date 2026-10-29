import Foundation
import GRDB
import os
import StowCore
import StowSecrets
import Testing
@testable import StowEngine
@testable import StowStore

extension SchedulerTests {
    /// D-502: the daemon reads marked text again once per process, and stops
    /// (for launchd to start it afresh) while a reading is left stuck.
    @Test func theFirstRoundReadsMarkedTextAgainAndAStuckReadingEndsTheRun() async throws {
        let (archive, location, keys) = try confirmedArchive()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let account = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "G")
        try ArchiveAccounts(archive: archive).add(AccountRecord(account: account))
        let bytes = Data("From: a@example.org\r\nSubject: Sandpiper\r\n\r\nHello.\r\n".utf8)
        // Marked by an older parser, so this build reads it again.
        _ = try Importer(archive: archive, extractor: TextExtractor(), parserVersion: MIMEParser.version - 1).storeUnread(
            RawMessage(key: RawMessageKey(accountID: account.id, folder: "INBOX", uidValidity: 1, uid: 1),
                       internalDate: Date(timeIntervalSince1970: 1_756_720_800), size: bytes.count, bytes: bytes))
        try archive.database.close()

        let restart = OSAllocatedUnfairLock(initialState: false)
        let scheduler = Scheduler(
            openArchive: { try Archive.open(location, keys: keys) },
            makeSync: { _ in throw CocoaError(.featureUnsupported) },
            power: { PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false) },
            restartWhen: { restart.withLock { $0 } },
            sleep: { _ in }
        )
        _ = await scheduler.round()
        let check = try Archive.open(location, keys: keys)
        #expect(try await check.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE text_state = 'complete' AND subject = 'Sandpiper'")
        } == 1)
        try check.database.close()

        // `run` returns after the round in which a reading was left stuck.
        restart.withLock { $0 = true }
        await scheduler.run()
    }
}
