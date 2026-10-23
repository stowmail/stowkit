import ArgumentParser
import Foundation
import StowCore
import StowSecrets
import StowStore
import StowSync

@main
struct Stowmail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stowmail",
        abstract: "Stow: a local, encrypted, searchable email archive.",
        version: StowVersion.current,
        subcommands: [
            Doctor.self, AccountCommand.self, Folders.self, Sync.self,
            Rules.self, Init.self, Import.self, Stats.self, Search.self, OCR.self,
        ]
    )
}

/// Checks the local setup without revealing any secret.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check SQLCipher, the Keychain backend, app configuration and the development store. Prints no secret values."
    )

    @Option(name: .long, help: "Development store folder to check (default: \(DevStoreProtection.defaultRoot.path)).")
    var out: String?

    func run() async throws {
        CLI.bootstrapLogging()
        print("stowmail \(StowVersion.current)")

        let cipher = (try? EncryptedDatabase.cipherVersion()) ?? nil
        print("SQLCipher: \(cipher ?? "NOT LINKED")")

        let backend = KeychainBackend.fromEnvironment()
        print("Keychain backend: \(backend.rawValue)\(backend == .file ? " (until builds are signed, D-012)" : "")")
        print("FileVault: \(FileVault.isOn ? "on" : "OFF")\(backend == .file && !FileVault.isOn ? " (the file backend will refuse to run)" : "")")

        print("App configuration:")
        do {
            for row in try AppConfig.report() {
                print("  \(row.key): \(row.status.rawValue)")
            }
        } catch {
            print("  \(error)")
        }

        let root = CLI.storeRoot(out)
        let status = DevStoreProtection().status(of: root)
        print("Development store (unencrypted, D-015): \(root.path)")
        print("  exists: \(status.exists ? "yes" : "no (created and protected by the first sync)")")
        print("  excluded from Time Machine: \(status.excludedFromTimeMachine ? "yes" : "NO")")
        print("  Spotlight: \(DevStoreProtection.spotlightMarker) \(status.spotlightMarkerPresent ? "present" : "MISSING"), .noindex name \(status.noindexSuffix ? "yes" : "NO")")
        print("  outside git repositories: \(status.insideGitRepository ? "NO" : "yes")")
        print("  outside iCloud Drive: \(status.insideICloudDrive ? "NO" : "yes")")
        if status.exists {
            print("  sync may write here: \(status.isProtected ? "yes" : "NO (\(status.problems.joined(separator: "; ")))")")
        }

        // D-115: messages servers list but never return.
        let state = DevStoreProtection.defaultStateDirectory
        print("Sync state folder: \(state.path)")
        print("  excluded from Time Machine: \(DevStoreProtection().isStateDirectoryExcluded(state) ? "yes" : "NO (sync excludes it before writing)")")
        let ledgers = ((try? FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".unfetchable.json") }
        var recorded = 0, pending = 0
        for file in ledgers {
            let totals = await UnfetchableLedger(fileURL: file).totals()
            recorded += totals.recorded
            pending += totals.pending
        }
        print("Unfetchable messages (listed by the server, never returned, D-115): \(recorded) recorded and passed, \(pending) still being retried")
    }
}
