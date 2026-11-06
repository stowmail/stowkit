import Foundation
import StowCore

/// Everything that can stop a sync. Every associated string has already been
/// through `Redact.scrub`, so these are safe to print and log.
public enum SyncError: Error, Equatable, CustomStringConvertible {
    /// The refresh token was rejected or is missing. The account is marked and
    /// sync will not try again until the user signs in (D-110).
    case needsSignIn(AccountID)
    /// A Gmail account signed in before Stow moved to the Gmail API, under the
    /// previous, wider permission. Signing in once more fixes it; nothing archived
    /// is lost (D-583).
    case oldPermission(AccountID)
    /// Gmail says the account's token does not include the read permission,
    /// for example because it was unticked on Google's consent screen. The
    /// account is marked as needing sign-in (D-110, D-592).
    case permissionMissing(AccountID)
    /// A Google Workspace admin has blocked Stow or the Gmail API for this
    /// account. Signing in again cannot help, so the account is not marked (D-592).
    case blockedByAdmin
    /// The Gmail API is not enabled for Stow's Google project: Stow's fault, not
    /// the user's. Logged with the reason code only (D-592).
    case gmailAPIUnavailable
    /// The account was removed (disconnected) from Stow. Nothing is refreshed
    /// or saved for it; adding the address again reconnects it (A-12, D-513).
    case accountRemoved(AccountID)
    /// An import-only account: its mail came from files and nothing ever connects for it (D-568).
    case importOnly
    /// The server rejected XOAUTH2 even with a freshly refreshed token.
    case authenticationFailed(String)
    /// Sign-in worked but there is no IMAP mailbox behind the account, for
    /// example a personal Microsoft account made with a non-Microsoft address,
    /// or IMAP is turned off. Signing in again cannot help (D-116).
    case mailboxUnavailable(String)
    /// iCloud refused the app-specific password. The account is marked as
    /// needing sign-in and never retried: there is nothing to refresh (D-467 item 5).
    case passwordRefused(AccountID)
    /// Another IMAP server refused the password (D-570). Marked and never
    /// retried, as for iCloud: there is nothing to refresh.
    case serverPasswordRefused(AccountID)
    /// The server offers neither `AUTH=PLAIN` nor a usable `LOGIN`, the only
    /// ways Stow signs in with a password (D-570 item 3). Nothing was sent.
    case noSupportedSignIn
    /// The server's TLS certificate did not pass the system's check. Never
    /// skipped or overridden (D-467 item 2, D-570 item 4).
    case certificateRejected(String)
    /// The TLS handshake failed for a reason other than the certificate,
    /// usually because the port does not speak TLS from the start (for
    /// example port 143, which expects STARTTLS; D-570 item 2).
    case tlsHandshakeFailed(String)
    /// A password was about to go over a connection without TLS.
    /// Refused before anything was sent (D-467 item 2, D-570 item 1).
    case insecureConnection
    /// The server's name could not be looked up (DNS). No hostname in the
    /// text: hostnames are logged at debug level only.
    case hostNotFound(String)
    /// Something answered at the address but refused the connection on that port.
    case connectionRefused(String)
    case connectionFailed(String)
    /// The server closed the connection, usually with a BYE.
    case connectionClosed(String?)
    case timedOut
    /// The server asked Stow to slow down. Retried with back-off (D-107).
    case throttled(String)
    /// The provider had a fault on its side (an HTTP 5xx). Retried with back-off.
    case providerUnavailable(String)
    /// A provider limit for the day was reached (for example Gmail's bandwidth cap). Not retried today.
    case quotaExceeded(String)
    case commandFailed(command: String, status: String, text: String)
    case protocolViolation(String)
    /// Stow's own daily byte budget for this account is used up (D-106).
    case budgetExhausted(usedBytes: Int64, limitBytes: Int64)
    /// An `imap` account whose server details are not in the archive.
    case serverDetailsMissing
    /// No folder has the `\All` special-use flag, so Gmail's All Mail cannot be found.
    case allMailNotFound
    /// The development store is missing a protection (D-108). Lists what is missing.
    case devStoreUnprotected([String])
    case cancelled

    /// Whether reconnecting after a pause might help.
    public var isRetryable: Bool {
        switch self {
        case .connectionFailed, .connectionClosed, .timedOut, .throttled, .hostNotFound, .connectionRefused, .providerUnavailable: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .needsSignIn(let id):
            "Account \(id) needs to sign in again. Run `stowmail account signin \(id)`."
        case .oldPermission(let id):
            "Account \(id) was signed in under Google's previous permission. Stow now asks only to view your email, so sign in once more with `stowmail account signin \(id)`. Nothing archived is lost."
        case .permissionMissing(let id):
            "Google says Stow's access doesn't include permission to view your email, so Stow can't download a copy. Sign in again with `stowmail account signin \(id)` and leave that permission ticked. Nothing archived is lost."
        case .blockedByAdmin:
            "Your Google Workspace admin has blocked Stow from reading this account's mail. Ask your admin to allow Stow, or add a personal account instead."
        case .gmailAPIUnavailable:
            "Stow couldn't reach Gmail. This is our fault, not yours: the background sync tries again later, and an update will fix it."
        case .importOnly: "This is an import-only account: its mail came from files, and it never syncs."
        case .accountRemoved(let id):
            "Account \(id) was removed from Stow, so it no longer signs in or syncs. Add the address again with `stowmail account add` to reconnect it."
        case .authenticationFailed(let text):
            "The mail server rejected the sign-in (\(text)). Try `stowmail account signin`."
        case .mailboxUnavailable(let text):
            "Signed in, but the server would not open this account's mailbox over IMAP (\(text)). This can be a fault on Microsoft's side that clears by itself, or the account may have no Outlook.com or Exchange Online mailbox (for example one created with a non-Microsoft address), or IMAP may be turned off for it. Signing in again will not help. The background sync tries again once a day."
        case .passwordRefused(let id):
            "iCloud refused the app-specific password. It may have been revoked, your Apple Account password may have changed (which revokes every app-specific password), or it was mistyped. Make a new one at account.apple.com (Sign-In and Security, App-Specific Passwords) and enter it with `stowmail account signin \(id)`. Stow will not try again until then."
        case .serverPasswordRefused(let id):
            "The mail server refused the password. It may have been changed, the provider may want an app password for mail apps rather than your account password, or IMAP may be turned off in the provider's settings. Check those, then enter it with `stowmail account signin \(id)`. Stow will not try again until then."
        case .noSupportedSignIn:
            "The mail server offers no way to sign in that Stow uses. Stow signs in with a password over TLS, using AUTHENTICATE PLAIN or LOGIN, and this server offers neither. Nothing was sent."
        case .certificateRejected(let text):
            "The mail server's security certificate did not pass this Mac's check (\(text)), so Stow did not connect. The server may use a certificate this Mac does not trust, such as a self-signed one, or something on the network may be intercepting the connection; try another network. Stow never skips this check."
        case .tlsHandshakeFailed(let text):
            "The mail server did not start a secure (TLS) connection (\(text)). Stow only connects with TLS from the start, usually on port 993. Port 143 with STARTTLS is not supported. Check the port."
        case .insecureConnection:
            "Refused to send a password over a connection that is not encrypted. Nothing was sent."
        case .hostNotFound(let text):
            "Could not find the mail server: its name did not look up (\(text)). Check the server name, and that this Mac is online."
        case .connectionRefused(let text):
            "The mail server refused the connection on that port (\(text)). Check the port; for IMAP over TLS it is usually 993."
        case .connectionFailed(let text): "Could not connect to the mail server: \(text)"
        case .connectionClosed(let text): "The mail server closed the connection\(text.map { ": \($0)" } ?? ".")"
        case .timedOut: "The mail server stopped responding."
        case .throttled(let text): "The mail server asked Stow to slow down: \(text)"
        case .providerUnavailable(let text): "The mail service had a fault on its side: \(text). The background sync tries again."
        case .quotaExceeded(let text): "The provider's daily limit was reached: \(text). Try again tomorrow."
        case .commandFailed(let command, let status, let text): "\(command) failed (\(status)): \(text)"
        case .protocolViolation(let text): "Unexpected reply from the mail server: \(text)"
        case .budgetExhausted(let used, let limit):
            "Today's download budget for this account is used up (\(used / 1_000_000) of \(limit / 1_000_000) MB). Sync will continue from here next time."
        case .serverDetailsMissing:
            "This account's server details are not in the archive, so Stow does not know where to connect. Remove the account and add it again; its archived mail is kept."
        case .allMailNotFound: "Could not find Gmail's All Mail folder (no folder is flagged \\All)."
        case .devStoreUnprotected(let missing):
            "Refusing to write to the development store: \(missing.joined(separator: "; ")). See `stowmail doctor`."
        case .cancelled: "Sync cancelled."
        }
    }
}
