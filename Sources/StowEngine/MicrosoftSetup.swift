import Foundation
import Logging
import StowCore
import StowSync

/// The check a Microsoft sign-in passes before anything is saved (R21, D-677): sign in to
/// Outlook's IMAP server with the new access token and list the folders, as iCloud's password
/// is checked (D-467). A Microsoft account with no mailbox, or with IMAP turned off, signs in
/// to Microsoft but has nothing IMAP can open (D-116), so the app says so and stores nothing.
public enum MicrosoftSetup {
    private static let logger = Logger(label: "ee.getstow.engine.microsoft")

    /// Returns how many folders Outlook listed. Throws `SyncError.mailboxUnavailable` when there
    /// is no mailbox behind the account, any other failure as it came.
    public static func check(email: String, accessToken: String,
                             endpoint: IMAPEndpoint = ProviderProfile.microsoft.endpoint!,
                             timeouts: IMAPTimeouts = .default) async throws -> Int {
        let probe = Account(id: AccountID(rawValue: "probe"), provider: .microsoft, email: email, displayName: email)
        let session = try await IMAPSession.connect(to: endpoint, timeouts: timeouts)
        do {
            try await session.authenticate(user: SessionFactory.username(for: probe), accessToken: accessToken)
            let folders = try await session.listFolders()
            await session.logout()
            return folders.count
        } catch {
            await session.disconnect()
            if case SyncError.mailboxUnavailable = error { logger.notice("Microsoft account has no IMAP mailbox at sign-in") }
            throw error
        }
    }
}
