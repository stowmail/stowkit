import ArgumentParser
import Foundation
import StowCore
import StowSecrets
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
            let registry = CLI.registry()
            _ = try registry.all() // Fails early if the Keychain backend is unusable.

            print("Opening the browser to sign in to \(provider.rawValue). Waiting up to five minutes...")
            let grant = try await SignInFlow(client: OAuthClient(config: oauth)).run(loginHint: email, openBrowser: CLI.openBrowser)
            guard let address = grant.email ?? email else { throw OAuthError.noEmailAddress }
            if let email, email.lowercased() != address.lowercased() {
                throw ValidationError("You signed in as a different address from --email. Nothing was saved.")
            }

            let account = Account(id: .generate(), provider: provider.provider, email: address, displayName: name ?? address)
            try registry.add(AccountRecord(account: account))
            do {
                try CLI.tokenStore().save(grant.tokens, for: account.id)
            } catch {
                try? registry.remove(account.id, tokens: CLI.tokenStore())
                throw error
            }
            print("Added account \(account.id) (\(address)). Tokens are in the Keychain.")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List connected accounts.")

        func run() async throws {
            CLI.bootstrapLogging()
            let records = try CLI.registry().all()
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
            abstract: "Sign in again, for an account whose access was revoked or expired."
        )

        @Argument(help: "Account ID, ID prefix, address or name.")
        var account: String

        func run() async throws {
            CLI.bootstrapLogging()
            let registry = CLI.registry()
            var record = try registry.find(account)
            let config = try AppConfig.load()
            let oauth = OAuthProviderConfig.forProvider(record.account.provider, config: config)
            print("Opening the browser to sign in as \(record.account.email). Waiting up to five minutes...")
            let grant = try await SignInFlow(client: OAuthClient(config: oauth))
                .run(loginHint: record.account.email, openBrowser: CLI.openBrowser)
            if let address = grant.email, address.lowercased() != record.account.email.lowercased() {
                throw ValidationError("You signed in as a different address. Nothing was changed; add it as a new account instead.")
            }
            try CLI.tokenStore().save(grant.tokens, for: record.account.id)
            record.needsSignIn = false
            try registry.save(record)
            print("Signed in again. Account \(record.account.id) can sync.")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove an account and its tokens from the Keychain. Downloaded mail is left in place."
        )

        @Argument(help: "Account ID, ID prefix, address or name.")
        var account: String

        func run() async throws {
            CLI.bootstrapLogging()
            let registry = CLI.registry()
            let record = try registry.find(account)
            try registry.remove(record.account.id, tokens: CLI.tokenStore())
            print("Removed account \(record.account.id) and its Keychain items.")
            print("Stow's access is still listed in the account's security settings until you revoke it there.")
        }
    }
}
