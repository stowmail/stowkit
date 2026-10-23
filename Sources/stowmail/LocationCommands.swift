import ArgumentParser
import Foundation
import StowEngine
import StowSecrets
import StowStore

struct ArchiveLocationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive-location",
        abstract: "Show where the archive is, or point Stow at an archive folder.",
        discussion: """
            With a folder that already holds a Stow archive, Stow uses it from now on. Before any archive exists, it \
            chooses where `stowmail init` creates one. To move an existing archive, use `stowmail archive-move`. Local \
            disks only: APFS or Mac OS Extended, exFAT with a caution; network shares and cloud-synced folders are refused \
            (D-023). `default` goes back to ~/Library/Application Support/Stow.
            """
    )

    @Argument(help: "An archive folder, or `default`.") var folder: String?

    func run() async throws {
        let settings = ArchiveSettings()
        guard let folder else {
            let location = CLIArchive.location()
            let source = ProcessInfo.processInfo.environment["STOW_ARCHIVE_DIR"] != nil ? "from STOW_ARCHIVE_DIR"
                : settings.chosenFolder != nil ? "chosen" : "default"
            print("\(location.root.path) (\(source))")
            print(location.exists ? "Online." : settings.chosenFolder != nil ? "OFFLINE: not available. Is its disk connected?" : "No archive there yet.")
            let volume = ArchiveLocation.checkVolume(location.root)
            print("Disk: \(volume.fileSystem)\(Self.describe(volume.verdict))")
            return
        }
        let url = folder == "default" ? ArchiveLocation.defaultForCLI.root
            : URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let target = ArchiveLocation(root: url)
        let current = CLIArchive.location()
        if !target.exists, current.exists, current.root.path != url.path {
            throw ValidationError("There is no archive in \(url.path), and the current one is at \(current.root.path). To move it, run `stowmail archive-move \(url.path)`.")
        }
        let volume = ArchiveLocation.checkVolume(url)
        if case .refused(let reason) = volume.verdict { throw ArchiveLocationError.unsupportedVolume(reason) }
        if target.exists {
            // Prove this Mac's keys open it before switching.
            let archive = try Archive.open(target, keys: try CLI.keyManager().loadKeys(), readOnly: true)
            try archive.database.close()
        }
        settings.setChosenFolder(url.path == ArchiveLocation.defaultForCLI.root.path ? nil : url)
        print("Stow now uses \(url.path).\(Self.describe(volume.verdict))")
        if !target.exists { print("Run `stowmail init` to create the archive there.") }
        if ProcessInfo.processInfo.environment["STOW_ARCHIVE_DIR"] != nil {
            print("Note: STOW_ARCHIVE_DIR is set in this shell and takes precedence.")
        }
    }

    static func describe(_ verdict: ArchiveLocation.VolumeInfo.Verdict) -> String {
        switch verdict {
        case .suitable: ""
        case .warning(let caution): " Caution: \(caution)."
        case .refused(let reason): " Not suitable: \(reason)."
        }
    }
}

struct ArchiveMove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive-move",
        abstract: "Move the archive to another folder: copy, verify the copy, switch, then offer to delete the old one.",
        discussion: "The original is not changed until the copy has verified and Stow has switched to it."
    )

    @Argument(help: "An empty or new folder.") var folder: String

    func run() async throws {
        CLI.bootstrapLogging()
        let destination = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        var (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
        let old = archive.location
        if let caution = try ArchiveMover.check(old, destination: destination) { print("Caution: \(caution).") }
        let report = try ArchiveMover.copy(archive, to: destination, keys: try CLI.keyManager().loadKeys()) { step in print(step + "...") }
        print("The copy verified: \(report.rebuilt) messages rebuilt byte for byte, \(report.attachments) attachments intact.")
        if ProcessInfo.processInfo.environment["STOW_ARCHIVE_DIR"] != nil {
            print("STOW_ARCHIVE_DIR is set, so set it to \(destination.path) to use the copy. The old archive was left in place.")
            return
        }
        ArchiveSettings().setChosenFolder(destination.path == ArchiveLocation.defaultForCLI.root.path ? nil : destination)
        print("Stow now uses \(destination.path).")
        try archive.database.close()
        lock.release()
        archive = try CLIArchive.open()
        guard CLI.confirm("Delete the old copy at \(old.root.path)?") else {
            print("The old copy was kept. You can delete it later.")
            return
        }
        for url in [old.databaseURL, URL(fileURLWithPath: old.databaseURL.path + "-wal"), URL(fileURLWithPath: old.databaseURL.path + "-shm"),
                    old.rawDirectory, old.attachmentsDirectory, old.recoveryBundleURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        print("Deleted the old copy.")
    }
}
