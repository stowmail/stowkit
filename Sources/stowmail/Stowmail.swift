import ArgumentParser
import Foundation
import StowCore
import StowEngine
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
            Doctor.self, Status.self, Init.self, RecoveryKeyCommand.self, Recover.self, AccountCommand.self, Folders.self,
            Sync.self, Size.self, Daemon.self, Verify.self, Export.self, Rules.self, Tidy.self, Remove.self, Removed.self, Restore.self,
            Coverage.self, DeletionCheckCommand.self, ArchiveLocationCommand.self, ArchiveMove.self, Import.self, Stats.self, Search.self, ThreadCommand.self, OCR.self, MCPCommand.self,
        ]
    )
}

/// Checks the local setup without revealing any secret.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check SQLCipher, the Keychain, app configuration, the archive and the background sync. Prints no secret values."
    )

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

        let location = CLIArchive.location()
        print("Archive: \(location.root.path)")
        let volume = ArchiveLocation.checkVolume(location.root)
        switch volume.verdict {
        case .suitable: print("  disk: \(volume.fileSystem), suitable")
        case .warning(let caution): print("  disk: \(volume.fileSystem). Caution: \(caution).")
        case .refused(let reason): print("  disk: \(volume.fileSystem). NOT SUITABLE: \(reason).")
        }
        if location.exists {
            print("  database: present\(RecoveryBundle.exists(in: location.root) ? ", recovery bundle present" : ", NO recovery bundle")")
            if let archive = try? CLIArchive.open(readOnly: true) {
                switch ArchiveSetup.recoveryState(archive) {
                case .confirmed: print("  recovery key confirmed: yes")
                case .unconfirmed: print("  recovery key confirmed: NO (run `stowmail recovery-key create`)")
                case .none: print("  recovery key: NONE MADE YET (run `stowmail recovery-key create`)")
                }
                if ArchiveSetup.hasUnconfirmedNewKey(archive) {
                    print("  a new recovery key was made but not confirmed; your old key still works")
                }
                // Nil also for an archive no v2 build has opened for writing yet.
                if let unread = try? UnreadText.collect(archive) {
                    print(unread.total > 0 ? "  \(unread.summary)" : "  emails Stow could not read in full: none")
                } else {
                    print("  emails Stow could not read in full: not counted until this build upgrades the archive (schema v2)")
                }
            } else {
                print("  could not open it with this Mac's keys")
            }
        } else if ArchiveSettings().chosenFolder != nil {
            print("  OFFLINE: the chosen folder is not available (is its disk connected?)")
        } else {
            print("  not created yet (run `stowmail init`)")
        }

        if let archive = try? CLIArchive.open(readOnly: true), let records = try? CLIArchive.accounts(archive).all(), !records.isEmpty {
            // The kind of credential and whether it is there; never its value or length (D-467 item 7).
            print("Accounts:")
            for record in records where record.isConnected {
                let id = record.account.id
                let present = record.account.provider.oauth == nil
                    ? (try? CLI.passwordStore().hasPassword(for: id)) == true
                    : ((try? CLI.tokenStore().tokens(for: id)) ?? nil) != nil
                print("  \(id.rawValue.prefix(8)) \(record.account.provider.rawValue): \(record.account.provider.credentialKind.label) \(present ? "in the Keychain" : "MISSING (run `stowmail account signin \(id.rawValue.prefix(8))`)")")
            }
        }

        print("Background sync: \(LaunchAgent.isInstalled ? (LaunchAgent.isLoaded() ? "installed and running" : "installed, not running") : "not installed (`stowmail daemon install`)")")
        print("Logs: \(LaunchAgent.logDirectory.path)")
        print("Power: \(PowerState.current().pauseReason.map { "sync would pause now (\($0))" } ?? "sync may run")")

        let root = DevStoreProtection.defaultRoot
        if FileManager.default.fileExists(atPath: root.path) {
            let status = DevStoreProtection().status(of: root)
            print("Phase 1 development store (unencrypted, D-015): \(root.path)")
            print("  protected: \(status.isProtected ? "yes" : "NO (\(status.problems.joined(separator: "; ")))")")
            print("  It is deleted once real mail is in the encrypted archive and verified.")
        }
    }
}
