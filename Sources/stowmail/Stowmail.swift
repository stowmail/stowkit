import ArgumentParser
import Foundation
import StowCore
import StowSecrets
import StowStore

@main
struct Stowmail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stowmail",
        abstract: "Stow: a local, encrypted, searchable email archive.",
        version: StowVersion.current,
        subcommands: [Doctor.self, Init.self, Import.self, Stats.self, Search.self, OCR.self]
    )
}

/// Checks the local setup without revealing any secret.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check SQLCipher, the Keychain backend and app configuration. Prints no secret values."
    )

    func run() async throws {
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
    }
}
