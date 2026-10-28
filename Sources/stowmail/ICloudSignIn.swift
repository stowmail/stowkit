import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowSecrets
import StowStore
import StowSync

/// `stowmail account add icloud` and `account signin` for an iCloud account
/// (D-467). The password is typed at a prompt that does not echo, or piped on
/// standard input; there is no flag or environment variable for it.
enum ICloudSignIn {
    /// Printed before the prompt (`docs/ui-notes/icloud-app-specific-password.md`).
    static let instructions = """
        iCloud needs an app-specific password, not your Apple Account password.
        To make one: go to account.apple.com and sign in, choose Sign-In and Security, then App-Specific Passwords.
        Click +, name it Stow, and copy the password Apple shows (it looks like abcd-efgh-ijkl-mnop).
        Stow only downloads a copy of your mail to this Mac and never changes anything in your mailbox.
        """

    /// Printed when an iCloud account is removed (D-467 item 6).
    static let revokeSteps = "The app-specific password still works until you revoke it: go to account.apple.com, Sign-In and Security, App-Specific Passwords, and remove Stow."

    static func add(email: String?, name: String?) async throws {
        guard let email else {
            throw ValidationError("For iCloud, give the address with --email, for example `stowmail account add icloud --email name@icloud.com`.")
        }
        // Before the password is asked for: a Gmail or Outlook address is never iCloud Mail.
        do {
            _ = try ICloudSetup.checkAddress(email)
        } catch let error as ICloudSetup.SetupError {
            throw ValidationError(error.description)
        }
        let archive = try CLIArchive.open()
        let accounts = CLIArchive.accounts(archive)
        print(instructions)
        let password = try readPassword()
        print("Checking the password with iCloud...")
        do {
            switch try await ICloudSetup.add(email: email, name: name, password: password,
                                             accounts: accounts, passwords: CLI.passwordStore()) {
            case .added(let id):
                print("Added account \(id) (\(email.trimmingCharacters(in: .whitespaces))). iCloud accepted the password; it is in the Keychain and will not be shown again.")
            case .reconnected(let id):
                print("Reconnected account \(id). Its archived mail was kept; sync carries on from where it stopped. The password is in the Keychain.")
            }
        } catch let error as ICloudSetup.SetupError {
            throw ValidationError(error.description)
        }
    }

    static func signInAgain(_ record: AccountRecord, accounts: ArchiveAccounts) async throws {
        print("Enter a new app-specific password for \(record.account.email).")
        print(instructions)
        let password = try readPassword()
        print("Checking the password with iCloud...")
        do {
            try await ICloudSetup.replacePassword(of: record, with: password, accounts: accounts, passwords: CLI.passwordStore())
        } catch let error as ICloudSetup.SetupError {
            throw ValidationError(error.description + " The stored password was not changed.")
        }
        print("iCloud accepted the new password and it replaced the old one. Account \(record.account.id) can sync.")
    }

    /// Reads and shape-checks the password. The typed text lives only in this
    /// function; what leaves it describes itself as redacted.
    private static func readPassword() throws -> AppSpecificPassword {
        fflush(stdout)
        guard let typed = CLI.askSecretOrReadLine("App-specific password (not shown as you type): ") else {
            throw ValidationError(AppSpecificPassword.ShapeError.empty.description)
        }
        do {
            return try AppSpecificPassword(typed: typed)
        } catch let error as AppSpecificPassword.ShapeError {
            throw ValidationError(error.description)
        }
    }
}
