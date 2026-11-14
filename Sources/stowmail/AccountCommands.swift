import ArgumentParser
import Foundation
import StowCore
import StowSecrets
import StowStore
import StowSync

struct AccountCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "account",
        abstract: "Add, list, re-authorise and remove mail accounts.",
        subcommands: [Add.self, List.self, SignIn.self, Disconnect.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sign in to a Gmail or Microsoft account in the browser, or an iCloud or other IMAP account with a password, and add it.",
            discussion: """
                For icloud and imap, --email is required and the password is asked for at a prompt that does not show it, or read as one line from standard input when that is not a terminal. There is no flag or environment variable for it.

                For imap, also give --preset for a known provider, or --host (and --port if not 993) for another server. Stow connects with TLS from the first byte only; STARTTLS and port 143 are not supported. The username defaults to the address. Presets: \(IMAPSignIn.presetList).
                """
        )

        @Argument(help: "gmail, microsoft, icloud or imap")
        var provider: ProviderArgument

        @Option(name: .long, help: "A friendly name, for example \"Personal\".")
        var name: String?

        @Option(name: .long, help: "The address, if the provider does not report it. Also pre-fills the sign-in page.")
        var email: String?

        @Option(name: .long, help: "imap only: a known provider's server, for example fastmail or gmx.")
        var preset: String?

        @Option(name: .long, help: "imap only: the IMAP server's name, for example imap.example.com.")
        var host: String?

        @Option(name: .long, help: "imap only, with --host: the port for IMAP over TLS (default 993).")
        var port: Int?

        @Option(name: .long, help: "imap only: the IMAP username, if it is not the address.")
        var username: String?

        func run() async throws {
            CLI.bootstrapLogging()
            if provider == .imap {
                return try await IMAPSignIn.add(email: email, preset: preset, host: host, port: port, username: username, name: name)
            }
            guard preset == nil, host == nil, port == nil, username == nil else {
                throw ValidationError("--preset, --host, --port and --username are for imap accounts only.")
            }
            guard let oauthProvider = provider.provider.oauth else {
                return try await ICloudSignIn.add(email: email, name: name)
            }
            let config = try AppConfig.load()
            let oauth = OAuthProviderConfig.forProvider(oauthProvider, config: config)
            let archive = try CLIArchive.open()
            let accounts = CLIArchive.accounts(archive)

            print("Signing in to \(provider.rawValue) in the browser. Waiting up to five minutes...")
            let grant = try await SignInFlow(client: OAuthClient(config: oauth)).run(loginHint: email, openBrowser: CLI.openBrowser)
            guard let address = grant.email ?? email else { throw OAuthError.noEmailAddress }
            if let email, email.lowercased() != address.lowercased() {
                throw ValidationError("You signed in as a different address from --email. Nothing was saved.")
            }

            // An account disconnected earlier keeps its ID and archived mail, and is simply reconnected (D-032).
            if let earlier = try accounts.disconnected(provider: provider.provider, email: address) {
                try CLI.tokenStore().save(grant.tokens, for: earlier.account.id)
                try accounts.reconnect(earlier.account.id)
                print("Reconnected account \(earlier.account.id) (\(address)). Its archived mail was kept; sync carries on from where it stopped.")
                return
            }
            let account = Account(id: .generate(), provider: provider.provider, email: address, displayName: name ?? address)
            try accounts.add(AccountRecord(account: account))
            do {
                try CLI.tokenStore().save(grant.tokens, for: account.id)
            } catch {
                try? accounts.disconnect(account.id)
                throw error
            }
            print("Added account \(account.id) (\(address)). Tokens are in the Keychain.")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List accounts, including disconnected ones whose mail is kept.")

        func run() async throws {
            CLI.bootstrapLogging()
            let archive = try CLIArchive.open(readOnly: true)
            let records = try CLIArchive.accounts(archive).all()
            if records.isEmpty {
                print("No accounts. Add one with `stowmail account add gmail`, `stowmail account add microsoft`, `stowmail account add icloud --email <address>` or `stowmail account add imap --email <address> --preset <id>`.")
            }
            let servers = ArchiveServers(archive: archive)
            for record in records {
                print(CLI.describe(record))
                if record.account.provider == .imap, let stored = try servers.server(for: record.account.id) {
                    print("    \(IMAPSignIn.describe(stored))")
                }
            }
        }
    }

    struct SignIn: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "signin",
            abstract: "Sign in again, for an account whose access was revoked or expired, or on a new Mac."
        )

        @Argument(help: "Account ID, ID prefix, address or name.")
        var account: String

        func run() async throws {
            CLI.bootstrapLogging()
            let accounts = CLIArchive.accounts(try CLIArchive.open())
            let record = try accounts.find(account)
            guard record.account.provider.syncs else { throw SyncError.importOnly }
            if record.account.provider == .imap {
                return try await IMAPSignIn.signInAgain(record, accounts: accounts)
            }
            guard let oauthProvider = record.account.provider.oauth else {
                return try await ICloudSignIn.signInAgain(record, accounts: accounts)
            }
            let config = try AppConfig.load()
            let oauth = OAuthProviderConfig.forProvider(oauthProvider, config: config)
            print("Signing in as \(record.account.email) in the browser. Waiting up to five minutes...")
            let grant = try await SignInFlow(client: OAuthClient(config: oauth))
                .run(loginHint: record.account.email, openBrowser: CLI.openBrowser)
            if let address = grant.email, address.lowercased() != record.account.email.lowercased() {
                throw ValidationError("You signed in as a different address. Nothing was changed; add it as a new account instead.")
            }
            try CLI.tokenStore().save(grant.tokens, for: record.account.id)
            if record.isConnected {
                try accounts.setNeedsSignIn(record.account.id, false)
            } else {
                try accounts.reconnect(record.account.id)
            }
            print("Signed in again. Account \(record.account.id) can sync.")
        }
    }

    /// `remove` until 0.2.0, kept as an alias. "Remove" read as if mail were deleted;
    /// nothing is (D-032, D-604).
    struct Disconnect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "disconnect",
            abstract: "Disconnect an account: stop syncing it and delete its tokens or password. Its archived mail is kept, and nothing changes in the mailbox.",
            discussion: """
                For a Google account, Stow also asks Google to end its access to the account. That signs Stow out of the same Google account on any other Mac and in the app as well as the command-line tool. If Google cannot be reached the account is still disconnected and the tokens are still deleted; you are then told how to remove access in your Google Account.
                """,
            aliases: ["remove"]
        )

        @Argument(help: "Account ID, ID prefix, address or name.")
        var account: String

        func run() async throws {
            CLI.bootstrapLogging()
            let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
            defer { lock.release() }
            let accounts = CLIArchive.accounts(archive)
            let record = try accounts.find(account)
            // Google: ask Google to end Stow's access first, then delete the tokens whatever it
            // answers (L-3, D-810). Nothing here waits on Google for more than ten seconds.
            let revocation = try await CredentialRemoval.discard(record.account, tokens: CLI.tokenStore(), passwords: CLI.passwordStore())
            try accounts.disconnect(record.account.id)
            guard record.account.provider.syncs else {
                print("Disconnected import-only account \(record.account.id). Its imported mail is kept and still searchable.")
                return
            }
            print("Disconnected account \(record.account.id). It no longer syncs and its \(record.account.provider.credentialKind.label) \(record.account.provider.oauth == nil ? "is" : "are") deleted from this Mac.")
            print("Its archived mail is kept and still searchable. Adding the same address again reconnects it.")
            if record.account.provider == .imap {
                print(IMAPSignIn.revokeSteps)
            } else if record.account.provider.oauth == nil {
                // D-467 item 6: the password still works until revoked at Apple.
                print(ICloudSignIn.revokeSteps)
            } else if record.account.provider == .gmail, revocation?.accessEnded == true {
                print("Stow's access to this Google account has been removed at Google. That also signs Stow out of this account on any other Mac, and for the command-line tool and the app alike (D-810).")
            } else if record.account.provider == .gmail {
                print("Stow could not confirm with Google that its access was removed, so it is still listed in the account's security settings until you revoke it there (myaccount.google.com/permissions).")
            } else {
                // Microsoft has no revocation request for a public client (D-810).
                print("Stow's access is still listed in the account's security settings until you revoke it there.")
            }
        }
    }
}
