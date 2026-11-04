import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowSecrets
import StowStore
import StowSync

/// `stowmail account add imap` and `account signin` for an account on another
/// IMAP server (D-555, D-570, D-577). As for iCloud (D-467), the password is
/// typed at a prompt that does not echo, or piped on standard input; there is
/// no flag or environment variable for it. Credentials go only to the preset's
/// host or the host given with --host: a preset is never picked for the user.
enum IMAPSignIn {
    /// For `account add --help`.
    static let presetList = IMAPPreset.all.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")

    /// Printed before the prompt, and at removal.
    static let general = "Stow only downloads a copy of your mail to this Mac and never changes anything in your mailbox. The password stays in this Mac's Keychain and is sent only to this server, over an encrypted connection."

    /// Printed when an account is removed (D-467 item 6, for any provider).
    static let revokeSteps = "If you made an app password for Stow, it still works until you remove it in your mail provider's security settings."

    /// Which server, from the flags. Exactly one of --preset and --host.
    static func server(email: String, preset: String?, host: String?, port: Int?, username: String?) throws -> ServerProfile {
        let user = username ?? email
        do {
            switch (preset, host) {
            case (let id?, nil):
                guard port == nil else {
                    throw ValidationError("A preset's server and port are fixed. Leave out --port, or use --host for another server.")
                }
                guard let preset = IMAPPreset.withID(id) else { throw ServerProfileError.unknownPreset(id) }
                return try ServerProfile(preset: preset, username: user)
            case (nil, let host?):
                return try ServerProfile(host: host, port: port ?? 993, username: user)
            case (_?, _?):
                throw ValidationError("Give either --preset or --host, not both.")
            case (nil, nil):
                let domain = EmailAddress(address: email).domain
                let hint = IMAPPreset.forDomain(domain).map { " For this address that is probably `--preset \($0.id)` (\($0.name))." } ?? ""
                throw ValidationError("Say which server to use: --preset <id> for a known provider, or --host <server> for another one.\(hint) Presets: \(presetList). Nothing was sent.")
            }
        } catch let error as ServerProfileError {
            throw ValidationError(error.description)
        }
    }

    static func add(email: String?, preset: String?, host: String?, port: Int?, username: String?, name: String?) async throws {
        guard let email else {
            throw ValidationError("For imap, give the address with --email, for example `stowmail account add imap --email name@example.com --preset fastmail`.")
        }
        // Before anything else: a Gmail, Outlook, iCloud or Proton address goes elsewhere.
        let address: String
        do {
            address = try IMAPSetup.checkAddress(email)
        } catch let error as IMAPSetup.SetupError {
            throw ValidationError(error.description)
        }
        let server = try server(email: address, preset: preset, host: host, port: port, username: username)
        let archive = try CLIArchive.open()
        let accounts = CLIArchive.accounts(archive)
        print(describe(server))
        if let advice = server.preset?.signInAdvice { print(advice) }
        print(general)
        let password = try readPassword()
        print("Signing in to the server...")
        fflush(stdout)
        do {
            switch try await IMAPSetup.add(email: address, server: server, name: name, password: password,
                                           accounts: accounts, passwords: CLI.passwordStore()) {
            case .added(let id, let report):
                print("Added account \(id) (\(address)). The server accepted the password; it is in the Keychain and will not be shown again.")
                printReport(report)
            case .reconnected(let id, let report):
                print("Reconnected account \(id). Its archived mail was kept; sync carries on from where it stopped. The password is in the Keychain.")
                printReport(report)
            }
        } catch let error as IMAPSetup.SetupError {
            throw ValidationError(error.description)
        }
    }

    static func signInAgain(_ record: AccountRecord, accounts: ArchiveAccounts) async throws {
        guard let server = try ServerProfile.forAccount(record.account, in: accounts.archive) else { throw SyncError.serverDetailsMissing }
        print("Enter a new password for \(record.account.email).")
        print(describe(server))
        if let advice = server.preset?.signInAdvice { print(advice) }
        let password = try readPassword()
        print("Signing in to the server...")
        fflush(stdout)
        let report: IMAPSetup.SignInReport
        do {
            report = try await IMAPSetup.replacePassword(of: record, with: password, accounts: accounts, passwords: CLI.passwordStore())
        } catch let error as IMAPSetup.SetupError {
            throw ValidationError(error.description.replacingOccurrences(of: "Nothing was saved.", with: "The stored password was not changed."))
        }
        print("The server accepted the new password and it replaced the old one. Account \(record.account.id) can sync.")
        printReport(report)
    }

    /// One line naming where the password will go: the user can stop here if it is wrong.
    static func describe(_ server: ServerProfile) -> String {
        "Server: \(server.host), port \(server.port), TLS\(server.preset.map { " (\($0.name) preset)" } ?? ""). Username: \(server.username)."
    }

    /// One line for `account list` and `doctor`.
    static func describe(_ stored: AccountServer) -> String {
        "server \(stored.host):\(stored.port) (\(stored.security)), username \(stored.username)\(stored.preset.map { ", preset \($0)" } ?? "")"
    }

    static func printReport(_ report: IMAPSetup.SignInReport) {
        print("The server listed \(report.folderCount) folders.")
        for line in missingLines(report.missingOptional) { print(line) }
    }

    /// What each missing extension changes, in words. SPECIAL-USE is about
    /// finding folders, the rest about how quickly changes are noticed.
    static func missingLines(_ missing: [String]) -> [String] {
        var lines: [String] = []
        if missing.contains("SPECIAL-USE") {
            lines.append("It does not mark its Sent, Trash and Junk folders (SPECIAL-USE), so Stow finds them by name.")
        }
        let rest = missing.filter { $0 != "SPECIAL-USE" }
        if !rest.isEmpty {
            let it = rest.count == 1 ? "it" : "them"
            lines.append("It does not offer \(rest.joined(separator: ", ")). Sync works without \(it); it may be slower to notice changes.")
        }
        return lines
    }

    /// Reads and checks the password. The typed text lives only in this
    /// function; what leaves it describes itself as redacted.
    private static func readPassword() throws -> MailPassword {
        fflush(stdout)
        guard let typed = CLI.askSecretOrReadLine("Password (not shown as you type): ") else {
            throw ValidationError(MailPassword.ServerPasswordError.empty.description)
        }
        do {
            return try MailPassword(serverPassword: typed)
        } catch let error as MailPassword.ServerPasswordError {
            throw ValidationError(error.description)
        }
    }
}
