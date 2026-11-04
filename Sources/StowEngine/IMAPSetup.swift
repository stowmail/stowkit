import Foundation
import Logging
import StowCore
import StowSecrets
import StowStore
import StowSync

/// Adding an account on another IMAP server (D-555, D-570): a preset such as
/// Fastmail or GMX, or a server the user typed.
///
/// As for iCloud (D-467), the password is checked against the server first
/// (sign in, read capabilities, list folders, log out) and saved only once the
/// server has accepted it. The account and its server details are then
/// written together (`account_servers`, D-577).
public enum IMAPSetup {
    /// What adding did, with what the server said at sign-in.
    public enum Outcome: Sendable, Equatable {
        case added(AccountID, SignInReport)
        /// An account removed earlier, same address and same server, connected again with its archived mail (D-032).
        case reconnected(AccountID, SignInReport)
    }

    /// Why adding stopped before or at sign-in. Each has its own message (D-082).
    public enum SetupError: Error, Equatable, CustomStringConvertible {
        /// The server did not accept the username and password together.
        case passwordRefused(presetAdvice: String?)
        /// The address is not one a mailbox can have.
        case notAnAddress
        /// The address belongs to a provider Stow signs in to its own way.
        case ownProvider(OwnProvider)
        /// An account with this address is already connected.
        case alreadyAdded(AccountID)
        /// This address was archived from a different server (host, port or
        /// username), so its archived folders belong to that one (D-577).
        case differentServer(AccountID)

        public var description: String {
            switch self {
            case .passwordRefused(let advice):
                "The server didn't accept the username and password. Check the username (usually your full address) and the password. "
                    + (advice.map { "\($0) " } ?? "Many providers want an app password for mail apps rather than your account password, and some need IMAP turned on in their settings first. ")
                    + "Nothing was saved."
            case .notAnAddress:
                "Enter the mailbox's address, for example name@example.com. Nothing was sent."
            case .ownProvider(let provider):
                provider.message
            case .alreadyAdded(let id):
                "This address is already added as account \(id). To enter a new password for it, run `stowmail account signin \(id)`."
            case .differentServer(let id):
                "This address was archived earlier as account \(id) from a different server, username or port. Stow can only reconnect it to the same server, because its archived folders belong to that one. Give the same server details as before (`stowmail account list` shows them), or ask for help moving it. Nothing was sent."
            }
        }
    }

    /// Providers whose addresses do not belong in `imap` (D-490 the other way round, brief step 5).
    public enum OwnProvider: Sendable, Equatable {
        case gmail, outlook, icloud, proton

        var message: String {
            switch self {
            case .gmail:
                "That is a Gmail address. Stow signs in to Gmail with Google's own sign-in: run `stowmail account add gmail`. Nothing was sent."
            case .outlook:
                "That is an Outlook address. Stow signs in to Outlook with Microsoft's own sign-in: run `stowmail account add microsoft`. Nothing was sent."
            case .icloud:
                "That is an iCloud Mail address. Run `stowmail account add icloud`, which asks for an app-specific password. Nothing was sent."
            case .proton:
                "That is a Proton Mail address. Proton Mail is reached through Proton Mail Bridge, which Stow does not support yet. Nothing was sent."
            }
        }

        static func forDomain(_ domain: String) -> OwnProvider? {
            let domain = domain.lowercased()
            let firstLabel = domain.split(separator: ".").first.map(String.init) ?? ""
            switch domain {
            case "gmail.com", "googlemail.com": return .gmail
            case "outlook.com", "hotmail.com", "live.com", "msn.com", "live.co.uk", "passport.com": return .outlook
            case "icloud.com", "me.com", "mac.com": return .icloud
            case "proton.me", "protonmail.com", "pm.me", "protonmail.ch": return .proton
            default: break
            }
            switch firstLabel {
            case "hotmail", "outlook": return .outlook
            default: return nil
            }
        }
    }

    /// Checks an address before anything is asked for or sent: it must look
    /// like an address, and not belong to Gmail, Outlook, iCloud or Proton.
    /// A custom domain is allowed even if Google or Microsoft host it: only
    /// the user knows, and a wrong guess is caught by the server. Returns the
    /// address trimmed.
    public static func checkAddress(_ typed: String) throws -> String {
        let email = typed.trimmingCharacters(in: .whitespaces)
        let address = EmailAddress(address: email)
        guard !address.localPart.isEmpty, address.domain.contains("."), !email.contains(" ") else {
            throw SetupError.notAnAddress
        }
        if let provider = OwnProvider.forDomain(address.domain) {
            throw SetupError.ownProvider(provider)
        }
        return email
    }

    /// What the server said at sign-in, for `account add` and `doctor`.
    public struct SignInReport: Sendable, Equatable {
        /// Capability names after sign-in, uppercased (brief step 3).
        public var capabilities: Set<String>
        public var folderCount: Int
        /// Optional extensions sync can use that this server lacks. Sync works
        /// without every one of them: UID ranges and UIDVALIDITY checks stand in.
        public var missingOptional: [String] {
            Self.optional.filter { !capabilities.contains($0) }
        }

        /// The extensions brief step 3 records.
        public static let optional = ["UIDPLUS", "CONDSTORE", "SPECIAL-USE", "ENABLE", "LIST-EXTENDED", "IDLE"]
    }

    private static let logger = Logger(label: "ee.getstow.engine.imap")

    /// Signs in with the password, reads the capabilities, lists the folders
    /// and logs out. Throws `SetupError.passwordRefused` if the server refuses
    /// it, `SyncError.noSupportedSignIn` if it offers no way Stow signs in, and
    /// any other failure (name lookup, port, certificate) as it came.
    public static func check(server: ServerProfile, password: MailPassword,
                             endpoint: IMAPEndpoint? = nil, timeouts: IMAPTimeouts = .default) async throws -> SignInReport {
        let session = try await IMAPSession.connect(to: endpoint ?? server.endpoint, timeouts: timeouts)
        do {
            try await session.authenticate(user: server.username, password: password, allowLogin: true)
            let capabilities = try await session.capabilities()
            let folders = try await session.listFolders()
            await session.logout()
            return SignInReport(capabilities: capabilities, folderCount: folders.count)
        } catch SyncError.authenticationFailed(let text) {
            await session.disconnect()
            logger.notice("An IMAP server refused a password at sign-in", metadata: ["reply": "\(text)"])
            throw SetupError.passwordRefused(presetAdvice: server.preset?.signInAdvice)
        } catch {
            await session.disconnect()
            throw error
        }
    }

    /// Adds an account on another IMAP server: checks the password with the
    /// server, saves it to the Keychain, then records the account and its
    /// server in one transaction. A removed account with the same address is
    /// reconnected instead, if its server is the same; otherwise nothing is sent.
    public static func add(email typed: String, server: ServerProfile, name: String?, password: MailPassword,
                           accounts: ArchiveAccounts, passwords: PasswordStore,
                           endpoint: IMAPEndpoint? = nil, timeouts: IMAPTimeouts = .default,
                           now: Date = Date()) async throws -> Outcome {
        let email = try checkAddress(typed)
        let servers = ArchiveServers(archive: accounts.archive)
        let all = try accounts.all()
        if let existing = all.first(where: { $0.isConnected && $0.account.provider == .imap && $0.account.email.lowercased() == email.lowercased() }) {
            throw SetupError.alreadyAdded(existing.account.id)
        }
        let earlier = try accounts.disconnected(provider: .imap, email: email)
        if let earlier {
            let stored = try servers.server(for: earlier.account.id)
            guard let stored, stored.host == server.host, stored.port == server.port, stored.username == server.username else {
                throw SetupError.differentServer(earlier.account.id)
            }
        }
        let report = try await check(server: server, password: password, endpoint: endpoint, timeouts: timeouts)
        let capabilities = report.capabilities.sorted()

        if let earlier {
            try passwords.save(password, for: earlier.account.id)
            try accounts.reconnect(earlier.account.id)
            try servers.setCapabilities(capabilities, for: earlier.account.id, at: now)
            return .reconnected(earlier.account.id, report)
        }
        let account = Account(id: .generate(), provider: .imap, email: email, displayName: name ?? email)
        try passwords.save(password, for: account.id)
        do {
            try servers.add(AccountRecord(account: account, addedAt: now), server: AccountServer(
                host: server.host, port: server.port, security: server.security.rawValue, username: server.username,
                preset: server.presetID, capabilities: capabilities, capabilitiesAt: now))
        } catch {
            try? passwords.delete(for: account.id)
            throw error
        }
        return .added(account.id, report)
    }

    /// Gives an `imap` account a new password: checks it with the account's
    /// stored server, and only then overwrites the stored one, clears "needs
    /// sign-in" and records the capabilities again. A refused password changes nothing.
    @discardableResult
    public static func replacePassword(of record: AccountRecord, with password: MailPassword,
                                       accounts: ArchiveAccounts, passwords: PasswordStore,
                                       endpoint: IMAPEndpoint? = nil, timeouts: IMAPTimeouts = .default,
                                       now: Date = Date()) async throws -> SignInReport {
        precondition(record.account.provider == .imap, "Only imap accounts have a server password")
        guard let server = try ServerProfile.forAccount(record.account, in: accounts.archive) else { throw SyncError.serverDetailsMissing }
        let report = try await check(server: server, password: password, endpoint: endpoint, timeouts: timeouts)
        try passwords.save(password, for: record.account.id)
        if record.isConnected {
            try accounts.setNeedsSignIn(record.account.id, false)
        } else {
            try accounts.reconnect(record.account.id)
        }
        try ArchiveServers(archive: accounts.archive).setCapabilities(report.capabilities.sorted(), for: record.account.id, at: now)
        return report
    }
}
