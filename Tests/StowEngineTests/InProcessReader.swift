import Foundation
import Logging
import StowCore
import StowExtraction
@testable import StowStore
@testable import StowEngine
import StowSync

// The engine takes the attachment reader from its caller (security review L-2). These tests
// use the command-line tool's, Apple's parsers in this process, through the calls they made
// before the seam, so the tests themselves did not change (D-821).

extension TextExtractor {
    init() { self.init(reader: LocalTextReader()) }
}

extension Importer {
    convenience init(archive: Archive, extractText: Bool = true, classifier: RuleClassifier? = nil) {
        self.init(archive: archive, reader: LocalTextReader(), extractText: extractText, classifier: classifier)
    }
}

extension ArchiveSyncStore {
    convenience init(archive: Archive) {
        self.init(archive: archive, importer: Importer(archive: archive))
    }
}

extension EngineSync {
    init(
        archive: Archive,
        settingsURL: URL = EngineRules.defaultSettingsURL,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        tokens: TokenProvider? = nil,
        sessions: @escaping @Sendable (Account) -> (@Sendable () async throws -> IMAPSession)
    ) {
        self.init(archive: archive, reader: LocalTextReader(), settingsURL: settingsURL, sleep: sleep, tokens: tokens, sessions: sessions)
    }

    init(archive: Archive, tokens: TokenProvider, settingsURL: URL = EngineRules.defaultSettingsURL) {
        self.init(archive: archive, reader: LocalTextReader(), tokens: tokens, settingsURL: settingsURL)
    }
}

extension Scheduler {
    init(
        settings: SchedulerSettings = SchedulerSettings(),
        openArchive: @escaping @Sendable () throws -> Archive,
        makeSync: @escaping @Sendable (Archive) throws -> EngineSync,
        power: @escaping @Sendable () -> PowerState = { PowerState.current() },
        hold: @escaping @Sendable () -> String? = { nil },
        restartWhen: @escaping @Sendable () -> Bool = { false },
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        logger: Logger = Logger(label: "ee.getstow.engine.scheduler")
    ) {
        self.init(settings: settings, openArchive: openArchive, makeSync: makeSync, reader: LocalTextReader(), power: power, hold: hold,
                  restartWhen: restartWhen, now: now, sleep: sleep, logger: logger)
    }
}
