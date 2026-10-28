import Foundation
import Logging
import StowCore
import StowSecrets
import StowStore
import StowSync

/// Adding an iCloud account, or giving one a new app-specific password (D-467).
///
/// The password is checked against iCloud first (sign in, list folders, log
/// out) and saved to the Keychain only once iCloud has accepted it. A refused
/// password is never saved, and an existing one is left as it was.
public enum ICloudSetup {
    /// What adding did.
    public enum Outcome: Sendable, Equatable {
        case added(AccountID)
        /// An account removed earlier, with the same address, connected again with its archived mail (D-032).
        case reconnected(AccountID)
    }

    /// Why adding or replacing stopped. Each has its own message (D-082).
    public enum SetupError: Error, Equatable, CustomStringConvertible {
        /// iCloud did not accept the address and password together.
        case passwordRefused
        /// The address is not one an iCloud account can have.
        case notAnAddress
        /// An account with this address is already connected.
        case alreadyAdded(AccountID)
        /// The address belongs to another mail service, so it has no iCloud mailbox.
        case notICloud(OtherService)

        public var description: String {
            switch self {
            case .passwordRefused:
                "iCloud didn't accept the address and app-specific password. Check that you entered your iCloud Mail address (it ends in @icloud.com, @me.com or @mac.com, unless you use your own domain with iCloud+), not the address you sign in to Apple with. If the address is right, make a new password at account.apple.com (Sign-In and Security, App-Specific Passwords) and enter it. If you changed your Apple Account password, every app-specific password was cancelled. Nothing was saved."
            case .notAnAddress:
                "Enter the iCloud Mail address, for example name@icloud.com. Nothing was saved."
            case .alreadyAdded(let id):
                "This address is already added as account \(id). To enter a new password for it, run `stowmail account signin \(id)`."
            case .notICloud(let service):
                "That is \(service.article) \(service.name) address, not iCloud Mail. \(service.nextStep) iCloud is only for iCloud Mail addresses: @icloud.com, @me.com or @mac.com, or your own domain set up with iCloud+. Nothing was sent."
            }
        }
    }

    /// A mail service whose addresses cannot be iCloud Mail. An Apple Account
    /// can be made with any address, so people type the one they sign in to
    /// Apple with; iCloud refuses it exactly as it refuses a wrong password
    /// (`NO Authentication Failed`, measured 28 Oct 2026), so it is caught here.
    public enum OtherService: Sendable, Equatable {
        case gmail, outlook, yahoo, aol, proton

        var name: String {
            switch self {
            case .gmail: "Gmail"
            case .outlook: "Outlook"
            case .yahoo: "Yahoo"
            case .aol: "AOL"
            case .proton: "Proton Mail"
            }
        }

        var article: String { self == .aol || self == .outlook ? "an" : "a" }

        var nextStep: String {
            switch self {
            case .gmail: "To archive it, run `stowmail account add gmail`."
            case .outlook: "To archive it, run `stowmail account add microsoft`."
            case .yahoo, .aol, .proton: "Stow archives Gmail, Outlook and iCloud Mail."
            }
        }

        static func forDomain(_ domain: String) -> OtherService? {
            let domain = domain.lowercased()
            let firstLabel = domain.split(separator: ".").first.map(String.init) ?? ""
            switch domain {
            case "gmail.com", "googlemail.com": return .gmail
            case "outlook.com", "hotmail.com", "live.com", "msn.com", "live.co.uk", "passport.com": return .outlook
            case "ymail.com", "rocketmail.com": return .yahoo
            case "aol.com", "aim.com": return .aol
            case "proton.me", "protonmail.com", "pm.me": return .proton
            default: break
            }
            // Country versions: hotmail.co.uk, outlook.fr, yahoo.de and so on.
            switch firstLabel {
            case "hotmail", "outlook": return .outlook
            case "yahoo": return .yahoo
            default: return nil
            }
        }
    }

    /// Checks an address before anything is asked for or sent: it must look
    /// like an address and must not belong to another mail service. Custom
    /// domains are allowed (iCloud+). Returns the address trimmed.
    public static func checkAddress(_ typed: String) throws -> String {
        let email = typed.trimmingCharacters(in: .whitespaces)
        let address = EmailAddress(address: email)
        guard !address.localPart.isEmpty, address.domain.contains("."), !email.contains(" ") else {
            throw SetupError.notAnAddress
        }
        if let service = OtherService.forDomain(address.domain) {
            throw SetupError.notICloud(service)
        }
        return email
    }

    private static let logger = Logger(label: "ee.getstow.engine.icloud")

    /// Signs in to iCloud with the password, lists the folders and logs out.
    /// Returns how many folders iCloud listed. Throws `SetupError.passwordRefused`
    /// if iCloud refuses it; any other failure (network, certificate) as it came.
    public static func check(email: String, password: AppSpecificPassword,
                             endpoint: IMAPEndpoint = ProviderProfile.icloud.endpoint,
                             timeouts: IMAPTimeouts = .default) async throws -> Int {
        let probe = Account(id: AccountID(rawValue: "probe"), provider: .icloud, email: email, displayName: email)
        let session = try await IMAPSession.connect(to: endpoint, timeouts: timeouts)
        do {
            try await session.authenticate(user: SessionFactory.username(for: probe), password: password)
            let folders = try await session.listFolders()
            await session.logout()
            return folders.count
        } catch SyncError.authenticationFailed(let text) {
            await session.disconnect()
            logger.notice("iCloud refused an app-specific password at sign-in", metadata: ["reply": "\(text)"])
            throw SetupError.passwordRefused
        } catch {
            await session.disconnect()
            throw error
        }
    }

    /// Adds an iCloud account: checks the password with iCloud, then saves it,
    /// then records the account. A removed account with the same address is
    /// reconnected instead, keeping its ID and archived mail.
    public static func add(email typed: String, name: String?, password: AppSpecificPassword,
                           accounts: ArchiveAccounts, passwords: PasswordStore,
                           endpoint: IMAPEndpoint = ProviderProfile.icloud.endpoint,
                           timeouts: IMAPTimeouts = .default) async throws -> Outcome {
        let email = try checkAddress(typed)
        if let existing = try accounts.all().first(where: {
            $0.isConnected && $0.account.provider == .icloud && $0.account.email.lowercased() == email.lowercased()
        }) {
            throw SetupError.alreadyAdded(existing.account.id)
        }
        _ = try await check(email: email, password: password, endpoint: endpoint, timeouts: timeouts)

        if let earlier = try accounts.disconnected(provider: .icloud, email: email) {
            try passwords.save(password, for: earlier.account.id)
            try accounts.reconnect(earlier.account.id)
            try accounts.setNeedsSignIn(earlier.account.id, false)
            return .reconnected(earlier.account.id)
        }
        let account = Account(id: .generate(), provider: .icloud, email: email, displayName: name ?? email)
        try passwords.save(password, for: account.id)
        do {
            try accounts.add(AccountRecord(account: account))
        } catch {
            try? passwords.delete(for: account.id)
            throw error
        }
        return .added(account.id)
    }

    /// Gives an iCloud account a new app-specific password: checks it with
    /// iCloud, and only then overwrites the stored one and clears "needs
    /// sign-in" (D-467 item 6). A refused password changes nothing.
    public static func replacePassword(of record: AccountRecord, with password: AppSpecificPassword,
                                       accounts: ArchiveAccounts, passwords: PasswordStore,
                                       endpoint: IMAPEndpoint = ProviderProfile.icloud.endpoint,
                                       timeouts: IMAPTimeouts = .default) async throws {
        precondition(record.account.provider == .icloud, "Only iCloud accounts have an app-specific password")
        _ = try await check(email: record.account.email, password: password, endpoint: endpoint, timeouts: timeouts)
        try passwords.save(password, for: record.account.id)
        if record.isConnected {
            try accounts.setNeedsSignIn(record.account.id, false)
        } else {
            try accounts.reconnect(record.account.id)
        }
    }
}
