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
        subcommands: [Add.self, List.self, SignIn.self, Remove.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sign in to a Gmail or Microsoft account in the browser, or an iCloud account with an app-specific password, and add it.",
            discussion: "For icloud, --email is required and the app-specific password is asked for at a prompt that does not show it, or read as one line from standard input when that is not a terminal. There is no flag or environment variable for it."
        )

        @Argument(help: "gmail, microsoft or icloud")
        var provider: ProviderArgument

        @Option(name: .long, help: "A friendly name, for example \"Personal\".")
        var name: String?

        @Option(name: .long, help: "The address, if the provider does not report it. Also pre-fills the sign-in page.")
        var email: String?

        func run() async throws {
            CLI.bootstrapLogging()
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

            // An account removed earlier keeps its ID and archived mail, and is simply reconnected (D-032).
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
            let records = try CLIArchive.accounts(try CLIArchive.open(readOnly: true)).all()
            if records.isEmpty {
                print("No accounts. Add one with `stowmail account add gmail`, `stowmail account add microsoft` or `stowmail account add icloud --email <address>`.")
            }
            for record in records {
                print(CLI.describe(record))
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

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Disconnect an account: stop syncing it and delete its tokens or app-specific password. Its archived mail is kept."
        )

        @Argument(help: "Account ID, ID prefix, address or name.")
        var account: String

        func run() async throws {
            CLI.bootstrapLogging()
            let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
            defer { lock.release() }
            let accounts = CLIArchive.accounts(archive)
            let record = try accounts.find(account)
            try CLI.tokenStore().delete(for: record.account.id)
            try CLI.passwordStore().delete(for: record.account.id)
            try accounts.disconnect(record.account.id)
            print("Disconnected account \(record.account.id). It no longer syncs and its \(record.account.provider.credentialKind.label) \(record.account.provider.oauth == nil ? "is" : "are") deleted from this Mac.")
            print("Its archived mail is kept and still searchable. Adding the same address again reconnects it.")
            if record.account.provider.oauth == nil {
                // D-467 item 6: the password still works until revoked at Apple.
                print(ICloudSignIn.revokeSteps)
            } else {
                print("Stow's access is still listed in the account's security settings until you revoke it there.")
            }
        }
    }
}
