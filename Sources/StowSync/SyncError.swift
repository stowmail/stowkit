import Foundation
import StowCore

/// Everything that can stop a sync. Every associated string has already been
/// through `Redact.scrub`, so these are safe to print and log.
public enum SyncError: Error, Equatable, CustomStringConvertible {
    /// The refresh token was rejected or is missing. The account is marked and
    /// sync will not try again until the user signs in (D-110).
    case needsSignIn(AccountID)
    /// The server rejected XOAUTH2 even with a freshly refreshed token.
    case authenticationFailed(String)
    /// Sign-in worked but there is no IMAP mailbox behind the account, for
    /// example a personal Microsoft account made with a non-Microsoft address,
    /// or IMAP is turned off. Signing in again cannot help (D-116).
    case mailboxUnavailable(String)
    case connectionFailed(String)
    /// The server closed the connection, usually with a BYE.
    case connectionClosed(String?)
    case timedOut
    /// The server asked Stow to slow down. Retried with back-off (D-107).
    case throttled(String)
    /// A provider limit for the day was reached (for example Gmail's bandwidth cap). Not retried today.
    case quotaExceeded(String)
    case commandFailed(command: String, status: String, text: String)
    case protocolViolation(String)
    /// Stow's own daily byte budget for this account is used up (D-106).
    case budgetExhausted(usedBytes: Int64, limitBytes: Int64)
    /// No folder has the `\All` special-use flag, so Gmail's All Mail cannot be found.
    case allMailNotFound
    /// The development store is missing a protection (D-108). Lists what is missing.
    case devStoreUnprotected([String])
    case cancelled
    /// The server listed messages it would not return. Those folders stopped
    /// before them and will try again next run (D-113).
    case messagesNotDownloaded(folders: Int, messages: Int)

    /// Whether reconnecting after a pause might help.
    public var isRetryable: Bool {
        switch self {
        case .connectionFailed, .connectionClosed, .timedOut, .throttled: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .needsSignIn(let id):
            "Account \(id) needs to sign in again. Run `stowmail account signin \(id)`."
        case .authenticationFailed(let text):
            "The mail server rejected the sign-in (\(text)). Try `stowmail account signin`."
        case .mailboxUnavailable(let text):
            "Signed in, but the server has no mailbox Stow can reach over IMAP for this account (\(text)). This usually means the Microsoft account has no Outlook.com or Exchange Online mailbox (for example it was created with a non-Microsoft address), or IMAP is turned off for it. Signing in again will not help; this account cannot be synced."
        case .connectionFailed(let text): "Could not connect to the mail server: \(text)"
        case .connectionClosed(let text): "The mail server closed the connection\(text.map { ": \($0)" } ?? ".")"
        case .timedOut: "The mail server stopped responding."
        case .throttled(let text): "The mail server asked Stow to slow down: \(text)"
        case .quotaExceeded(let text): "The provider's daily limit was reached: \(text). Try again tomorrow."
        case .commandFailed(let command, let status, let text): "\(command) failed (\(status)): \(text)"
        case .protocolViolation(let text): "Unexpected reply from the mail server: \(text)"
        case .budgetExhausted(let used, let limit):
            "Today's download budget for this account is used up (\(used / 1_000_000) of \(limit / 1_000_000) MB). Sync will continue from here next time."
        case .allMailNotFound: "Could not find Gmail's All Mail folder (no folder is flagged \\All)."
        case .devStoreUnprotected(let missing):
            "Refusing to write to the development store: \(missing.joined(separator: "; ")). See `stowmail doctor`."
        case .cancelled: "Sync cancelled."
        case .messagesNotDownloaded(let folders, let messages):
            "Incomplete: the server listed \(messages) message(s) in \(folders) folder(s) but would not return them. Those folders stopped there and will be retried next run; nothing after them was skipped."
        }
    }
}
