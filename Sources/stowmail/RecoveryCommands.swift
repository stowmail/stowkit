import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowSecrets
import StowStore

/// Creates the archive keys, an empty archive and its recovery key.
struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create the archive keys in the Keychain, an empty encrypted archive and its recovery key.",
        discussion: """
            The recovery key is shown once and must be confirmed by typing two of its groups back before any mail is \
            imported (D-007). Accounts added before the archive existed are moved into it. With --recovery-key-later, \
            the key is made afterwards with `stowmail recovery-key create`, as the app does after sign-in (D-055).
            """
    )

    @Flag(name: .long, help: "Create the archive and its keys only. Nothing is imported until `stowmail recovery-key create` is confirmed.")
    var recoveryKeyLater = false

    func run() async throws {
        CLI.bootstrapLogging()
        let location = CLIArchive.location()
        if !location.exists {
            // A chosen folder whose disk is not connected must not be created on the startup disk instead.
            let parent = location.root.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path) else { throw ArchiveLocationError.offline(parent.path) }
            switch ArchiveLocation.checkVolume(location.root).verdict {
            case .suitable: break
            case .warning(let caution): print("Caution: \(caution).")
            case .refused(let reason): throw ArchiveLocationError.unsupportedVolume(reason)
            }
        }
        if recoveryKeyLater {
            let archive = try ArchiveSetup.createArchive(location, keyManager: CLI.keyManager())
            print("Archive ready at \(archive.location.root.path)")
            try adoptAccounts(archive)
            switch ArchiveSetup.recoveryState(archive) {
            case .confirmed: print("Its recovery key was confirmed earlier. To replace it, run `stowmail recovery-key rotate`.")
            case .none, .unconfirmed:
                print("No recovery key yet, so no mail is imported. Add an account, then run `stowmail recovery-key create`.")
            }
            return
        }
        let (archive, recoveryKey) = try ArchiveSetup.initialise(location, keyManager: CLI.keyManager())
        print("Archive ready at \(archive.location.root.path)")
        if let recoveryKey {
            try RecoveryPrompt.showAndConfirm(archive, recoveryKey)
        } else {
            print("Its recovery key was confirmed earlier. To replace it, run `stowmail recovery-key rotate`.")
        }
        try adoptAccounts(archive)
    }

    private func adoptAccounts(_ archive: Archive) throws {
        let moved = try ArchiveSetup.adoptKeychainAccounts(archive, registry: CLI.keychainRegistry())
        if moved > 0 { print("Moved \(moved) account(s) into the archive. Their tokens stay in the Keychain.") }
    }
}

struct RecoveryKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recovery-key",
        abstract: "Make or replace the recovery key.",
        subcommands: [Create.self, Rotate.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make the archive's first recovery key, show it once and confirm it.",
            discussion: """
                For an archive made with `init --recovery-key-later`, or whose key was never confirmed. Refuses when a \
                confirmed key exists; `rotate` replaces one.
                """
        )

        func run() async throws {
            CLI.bootstrapLogging()
            let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
            defer { lock.release() }
            guard ArchiveSetup.recoveryState(archive) != .confirmed else { throw ArchiveSetupError.recoveryAlreadyConfirmed }
            let key = try ArchiveSetup.makeRecoveryKey(archive, keyManager: CLI.keyManager())
            try RecoveryPrompt.showAndConfirm(archive, key)
        }
    }

    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make a new recovery key, show it once and confirm it. The old one keeps working until the new one is confirmed.",
            discussion: """
                Only the small key bundle beside the archive is rewritten, once the new key is confirmed; the archive itself \
                is not re-encrypted, so backups made before the change still open with the old key.
                """
        )

        func run() async throws {
            CLI.bootstrapLogging()
            let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
            defer { lock.release() }
            let key = try ArchiveSetup.rotate(archive, keys: try CLI.keyManager().loadKeys())
            try RecoveryPrompt.showAndConfirm(archive, key)
        }
    }
}

/// Restores the archive keys onto a new Mac (D-031).
struct Recover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore an archive's keys onto this Mac from its recovery key.",
        discussion: """
            Point it at the archive folder (for example restored from Time Machine). It asks for the recovery key, checks the \
            keys open that archive, and saves them in this Mac's Keychain. It never replaces keys already there.
            """
    )

    @Option(name: .long, help: "The archive folder.") var archive: String

    func run() async throws {
        CLI.bootstrapLogging()
        let folder = URL(fileURLWithPath: (archive as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        guard let typed = CLI.askSecret("Recovery key (not shown as you type): ") else { throw ExitCode.failure }
        let key = try RecoveryKey(typed)
        try ArchiveSetup.recover(archiveFolder: folder, recoveryKey: key, keyManager: CLI.keyManager())
        print("The archive's keys are now in this Mac's Keychain.")
        if ProcessInfo.processInfo.environment["STOW_ARCHIVE_DIR"] == nil, folder.path != ArchiveLocation.defaultForCLI.root.path {
            ArchiveSettings().setChosenFolder(folder)
            print("Stow will use the archive at \(folder.path).")
        }
        print("Sign in again to each account on this Mac (`stowmail account list`, then `stowmail account signin <account>`): sign-ins do not move between Macs.")
    }
}

/// Showing a new recovery key once and having two groups typed back.
enum RecoveryPrompt {
    static func showAndConfirm(_ archive: Archive, _ key: RecoveryKey) throws {
        let groups = key.groups
        print("""

            Your recovery key. It is shown once and Stow never stores it:

                \(groups[0..<7].joined(separator: "-"))
                \(groups[7..<14].joined(separator: "-"))

            Keep it somewhere safe, such as your password manager or on paper. With it and a copy of
            the archive folder (for example from Time Machine), your mail can be opened on a new Mac.
            Without it, and without this Mac, the archive cannot be opened by anyone, including you.
            Treat it like a password: anyone with it and a copy of the archive can read your mail.

            """)
        _ = CLI.ask("Press Return once you have saved it. The screen is then cleared. ")
        // Clear the screen and the scrollback, so the key does not stay on display.
        print("\u{1B}[2J\u{1B}[3J\u{1B}[H", terminator: "")
        var generator = SystemRandomNumberGenerator()
        let (first, second) = ArchiveSetup.confirmationGroups(using: &generator)
        for attempt in 1...3 {
            let a = CLI.ask("Type group \(first + 1) of your recovery key (four characters): ") ?? ""
            let b = CLI.ask("Type group \(second + 1): ") ?? ""
            do {
                try ArchiveSetup.confirm(archive, recoveryKey: key, typed: [first: a, second: b])
                print("Recovery key confirmed. Stow can now import your mail.")
                return
            } catch ArchiveSetupError.groupMismatch {
                if attempt < 3 { print(ArchiveSetupError.groupMismatch.description) }
            }
        }
        try ArchiveSetup.discardUnconfirmedKey(archive)
        if ArchiveSetup.recoveryState(archive) == .confirmed {
            print("Not confirmed. Your old recovery key still works. Run `stowmail recovery-key rotate` to try again.")
        } else {
            print("Not confirmed. Run `stowmail recovery-key create` to get a new key; no mail is imported until one is confirmed.")
        }
        throw ExitCode.failure
    }
}
