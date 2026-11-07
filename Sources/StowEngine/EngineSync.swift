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
    /// Signs Gmail accounts in to the Gmail API (D-583). Without it a Gmail
    /// account cannot sync: its IMAP path is gone (D-601).
    let tokens: TokenProvider?

    public init(
        archive: Archive,
        settingsURL: URL = EngineRules.defaultSettingsURL,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        tokens: TokenProvider? = nil,
        sessions: @escaping @Sendable (Account) -> (@Sendable () async throws -> IMAPSession)
    ) {
        self.archive = archive
        self.settingsURL = settingsURL
        self.sleep = sleep
        self.tokens = tokens
        self.sessions = sessions
    }

    /// Sessions signed in with the account's tokens, to the provider's server.
    public init(archive: Archive, tokens: TokenProvider, settingsURL: URL = EngineRules.defaultSettingsURL) {
        self.init(archive: archive, settingsURL: settingsURL, tokens: tokens) { account in
            // An `imap` account's server is read from the archive at each connect (D-577).
            return { try await SessionFactory(account: account, in: archive, tokens: tokens).open() }
        }
    }

    /// Gmail through the Gmail API (D-583); every other account over IMAP. A
    /// Gmail account with no token provider gets the IMAP syncer, which refuses
    /// it (`SyncError.gmailUsesTheAPI`, D-601).
    public func syncer(for account: Account) throws -> any MailSyncer {
        let rules = try EngineRules.ruleSet(settings: settingsURL, archive: archive, account: account.id)
        let store = ArchiveSyncStore(archive: archive, importer: Importer(archive: archive, classifier: EngineRules.classifier(rules)))
        let profile = try ProviderProfile.forAccount(account, in: archive)
        if account.provider == .gmail, let tokens {
            return GmailSyncer(
                account: account,
                tokens: tokens,
                sink: store,
                state: store,
                budget: ByteBudget(limit: profile.dailyByteLimit, store: store, account: account.id),
                prioritiser: EngineRules.prioritiser(rules, ownAddress: account.email),
                sleep: sleep
            )
        }
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
