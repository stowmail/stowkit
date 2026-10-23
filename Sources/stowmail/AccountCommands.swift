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
            abstract: "Sign in to a Gmail or Microsoft account in the browser and add it."
        )

        @Argument(help: "gmail or microsoft")
        var provider: ProviderArgument

        @Option(name: .long, help: "A friendly name, for example \"Personal\".")
        var name: String?

        @Option(name: .long, help: "The address, if the provider does not report it. Also pre-fills the sign-in page.")
        var email: String?

        func run() async throws {
            CLI.bootstrapLogging()
            let config = try AppConfig.load()
            let oauth = OAuthProviderConfig.forProvider(provider.provider, config: config)
            let archive = try CLIArchive.open()
            let accounts = CLIArchive.accounts(archive)

            print("Opening the browser to sign in to \(provider.rawValue). Waiting up to five minutes...")
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
                print("No accounts. Add one with `stowmail account add gmail` or `stowmail account add microsoft`.")
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
            let config = try AppConfig.load()
            let oauth = OAuthProviderConfig.forProvider(record.account.provider, config: config)
            print("Opening the browser to sign in as \(record.account.email). Waiting up to five minutes...")
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
            abstract: "Disconnect an account: stop syncing it and delete its tokens. Its archived mail is kept."
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
            try accounts.disconnect(record.account.id)
            print("Disconnected account \(record.account.id). It no longer syncs and its tokens are deleted.")
            print("Its archived mail is kept and still searchable. Adding the same address again reconnects it.")
            print("Stow's access is still listed in the account's security settings until you revoke it there.")
        }
    }
}
