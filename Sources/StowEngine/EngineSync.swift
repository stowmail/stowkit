import Foundation
import StowCore
import StowStore
import StowSync

/// Builds an account's syncer writing straight into the archive (step 4):
/// the archive is both sink and sync state, the rules order the downloads and
/// label each message, and the byte budget is kept in the archive.
public struct EngineSync: Sendable {
    public let archive: Archive
    /// Opens a signed-in session for an account. Production uses `SessionFactory`.
    let sessions: @Sendable (Account) -> (@Sendable () async throws -> IMAPSession)
    let settingsURL: URL
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        archive: Archive,
        settingsURL: URL = EngineRules.defaultSettingsURL,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        sessions: @escaping @Sendable (Account) -> (@Sendable () async throws -> IMAPSession)
    ) {
        self.archive = archive
        self.settingsURL = settingsURL
        self.sleep = sleep
        self.sessions = sessions
    }

    /// Sessions signed in with the account's tokens, to the provider's server.
    public init(archive: Archive, tokens: TokenProvider, settingsURL: URL = EngineRules.defaultSettingsURL) {
        self.init(archive: archive, settingsURL: settingsURL) { account in
            let factory = SessionFactory(account: account, endpoint: ProviderProfile.forProvider(account.provider).endpoint, tokens: tokens)
            return { try await factory.open() }
        }
    }

    public func syncer(for account: Account) throws -> AccountSyncer {
        let rules = try EngineRules.ruleSet(settings: settingsURL, archive: archive, account: account.id)
        let store = ArchiveSyncStore(archive: archive, importer: Importer(archive: archive, classifier: EngineRules.classifier(rules)))
        let profile = ProviderProfile.forProvider(account.provider)
        return AccountSyncer(
            account: account,
            openSession: sessions(account),
            sink: store,
            state: store,
            budget: ByteBudget(limit: profile.dailyByteLimit, store: store, account: account.id),
            prioritiser: EngineRules.prioritiser(rules, ownAddress: account.email),
            sleep: sleep
        )
    }
}
