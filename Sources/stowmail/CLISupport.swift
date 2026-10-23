import AppKit
import ArgumentParser
import Foundation
import Logging
import StowCore
import StowSecrets
import StowSync

/// Shared plumbing for the commands.
enum CLI {
    /// Logs go to standard error. Level from STOW_LOG_LEVEL (trace, debug,
    /// info, notice, warning, error), default notice. Never logs secrets (D-014).
    private static let loggingBootstrapped: Bool = {
        let level = ProcessInfo.processInfo.environment["STOW_LOG_LEVEL"].flatMap(Logger.Level.init(rawValue:)) ?? .notice
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
        return true
    }()

    static func bootstrapLogging() {
        _ = loggingBootstrapped
    }

    static func storeRoot(_ out: String?) -> URL {
        guard let out else { return DevStoreProtection.defaultRoot }
        return URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    static func keychain() -> KeychainStore { KeychainStore() }
    static func registry() -> AccountRegistry { AccountRegistry(keychain: keychain()) }
    static func tokenStore() -> TokenStore { TokenStore(keychain: keychain()) }

    static func tokenProvider() throws -> TokenProvider {
        let config = try AppConfig.load()
        return TokenProvider(tokenStore: tokenStore(), registry: registry()) { provider in
            OAuthClient(config: OAuthProviderConfig.forProvider(provider, config: config))
        }
    }

    /// Opens the user's default browser (brief step 1: NSWorkspace).
    @Sendable static func openBrowser(_ url: URL) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened {
            print("Could not open the browser. Open this address yourself to continue:\n\(url.absoluteString)")
        }
    }

    static func describe(_ record: AccountRecord) -> String {
        let flag = record.needsSignIn ? "  NEEDS SIGN-IN" : ""
        return "\(record.account.id)  \(record.account.provider.rawValue)  \(record.account.email)  \"\(record.account.displayName)\"\(flag)"
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

enum ProviderArgument: String, ExpressibleByArgument, CaseIterable {
    case gmail
    case microsoft

    var provider: Provider {
        switch self {
        case .gmail: .gmail
        case .microsoft: .microsoft
        }
    }
}
