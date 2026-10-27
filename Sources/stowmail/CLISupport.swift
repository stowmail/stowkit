import AppKit
import ArgumentParser
import Foundation
import Logging
import StowCore
import StowEngine
import StowSecrets
import StowStore
import StowSync

/// Shared plumbing for the commands.
enum CLI {
    private nonisolated(unsafe) static var loggingBootstrapped = false
    private static let loggingLock = NSLock()

    /// Logs go to standard error and to `~/Library/Logs/Stow/stowmail.log`
    /// (D-040), both scrubbed. Level from STOW_LOG_LEVEL (trace, debug, info,
    /// notice, warning, error), default notice. Never logs secrets (D-014).
    /// The background sync passes `console: false`: launchd would copy every
    /// line into `daemon.out.log`, which is never rotated.
    static func bootstrapLogging(console: Bool = true) {
        loggingLock.withLock {
            guard !loggingBootstrapped else { return }
            loggingBootstrapped = true
            let level = ProcessInfo.processInfo.environment["STOW_LOG_LEVEL"].flatMap(Logger.Level.init(rawValue:)) ?? .notice
            LoggingSystem.bootstrap { label in
                let file = FileLogHandler(label: label, level: level)
                guard console else { return file }
                return MultiplexLogHandler([StandardErrorLogHandler(label: label, level: level), file])
            }
        }
    }

    static func storeRoot(_ out: String?) -> URL {
        guard let out else { return DevStoreProtection.defaultRoot }
        return URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// The Keychain under `STOW_KEYCHAIN_SERVICE` if set, so development and
    /// tests keep their keys and tokens apart from the real ones (D-208).
    static func keychain() -> KeychainStore {
        ArchiveOpening.keychain()
    }

    /// Phase 1's account list in the Keychain; only read to move it into the archive (D-032).
    static func keychainRegistry() -> AccountRegistry { AccountRegistry(keychain: keychain()) }
    static func tokenStore() -> TokenStore { TokenStore(keychain: keychain()) }
    static func keyManager() -> KeyManager { KeyManager(keychain: keychain()) }

    static func tokenProvider(accounts: any AccountDirectory) throws -> TokenProvider {
        let config = try AppConfig.load()
        return TokenProvider(tokenStore: tokenStore(), registry: accounts) { provider in
            OAuthClient(config: OAuthProviderConfig.forProvider(provider, config: config))
        }
    }

    /// Prints the sign-in address (D-465), then opens it in the user's default
    /// browser (brief step 1: NSWorkspace).
    @Sendable static func openBrowser(_ url: URL) async throws {
        print(SignInFlow.addressNotice(url))
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened {
            print("Could not open the browser. Open the sign-in address above yourself to continue.")
        }
    }

    static func describe(_ record: AccountRecord) -> String {
        let flag = !record.isConnected ? "  DISCONNECTED (mail kept)" : record.needsSignIn ? "  NEEDS SIGN-IN" : ""
        return "\(record.account.id)  \(record.account.provider.rawValue)  \(record.account.email)  \"\(record.account.displayName)\"\(flag)"
    }

    /// A size the way Finder writes it, for example "48 KB" or "9.8 GB".
    static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func megabytes(_ bytes: Int) -> String {
        megabytes(Int64(bytes))
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter.string(from: date)
    }

    /// Asks a question on the terminal; nil at end of input.
    static func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }

    static func confirm(_ prompt: String) -> Bool {
        guard let answer = ask(prompt + " [y/N] ") else { return false }
        return ["y", "yes"].contains(answer.lowercased())
    }

    /// Reads a secret without showing it as it is typed.
    static func askSecret(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard let result = readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF) else { return nil }
        let text = String(cString: result)
        buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        return text
    }
}

/// Opening the archive from the CLI: location from `STOW_ARCHIVE_DIR`, else
/// the folder chosen with `stowmail archive-location`, else
/// `~/Library/Application Support/Stow/`; keys from the Keychain (D-208, D-035).
enum CLIArchive {
    static func location() -> ArchiveLocation {
        ArchiveLocation.fromEnvironment()
    }

    /// Opens an existing archive. Never creates one: a missing archive at a
    /// chosen folder is "offline" (a disconnected disk), not a reason to start afresh.
    static func open(readOnly: Bool = false) throws -> Archive {
        do {
            return try ArchiveOpening.openExisting(location: location(), keys: CLI.keyManager(), readOnly: readOnly)
        } catch ArchiveOpeningError.noArchive(let path) {
            throw ValidationError("No archive at \(path). Run `stowmail init` first.")
        }
    }

    /// Opens the archive for writing and takes the writer lock, waiting up to
    /// ten minutes for the background sync to finish its round (D-035).
    static func openForWriting(requireRecovery: Bool = true) throws -> (Archive, ArchiveLock) {
        let archive = try open()
        if requireRecovery { try ArchiveSetup.requireConfirmed(archive) }
        let lock = try ArchiveLock.acquire(archive.location, wait: 600) {
            print("Waiting for the background sync to finish its current turn...")
        }
        return (archive, lock)
    }

    static func accounts(_ archive: Archive) -> ArchiveAccounts {
        ArchiveAccounts(archive: archive)
    }

    static func megabytes(_ bytes: Int) -> String {
        CLI.megabytes(Int64(bytes))
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
