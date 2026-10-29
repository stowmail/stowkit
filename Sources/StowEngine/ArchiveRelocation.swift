import Foundation
import StowSecrets
import StowStore

/// Moving the archive to another folder (`stowmail archive-move`), with the
/// writer lock held from the copy to the end (A-10, D-509):
///
/// 1. copy and verify (`ArchiveMover.copy`);
/// 2. warn if the installed background sync pins `STOW_ARCHIVE_DIR` elsewhere;
/// 3. leave `moved-to.json` in the old folder, flushed, before the switch is
///    saved, so nothing opens, writes to or creates an archive there again;
/// 4. switch the chosen folder;
/// 5. ask whether to delete the old copy, and delete it.
///
/// A background sync that opened the old folder before the switch waits for
/// the lock, then finds the marker and stops (`Scheduler`), and the daemon
/// starts afresh at the new place. The caller releases the lock afterwards;
/// the lock file and the marker stay in the old folder.
public enum ArchiveRelocation {
    public enum Outcome: Sendable, Equatable {
        /// `STOW_ARCHIVE_DIR` is set in this shell: copied and verified, nothing switched, the old copy kept, no marker.
        case copiedOnly
        /// Switched; the old copy was deleted or kept.
        case moved(deletedOld: Bool)
    }

    /// The warning to show when the installed agent pins `STOW_ARCHIVE_DIR`
    /// to anything but `destination`, else nil.
    public static func agentWarning(agentEnvironment: [String: String], destination: URL) -> String? {
        guard let pinned = agentEnvironment["STOW_ARCHIVE_DIR"], !pinned.isEmpty else { return nil }
        let pinnedURL = URL(fileURLWithPath: (pinned as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        guard pinnedURL.path != destination.standardizedFileURL.path else { return nil }
        return """
            The background sync is installed with STOW_ARCHIVE_DIR=\(pinned), so it will not follow the move: it stops \
            at the old folder until it is reinstalled. Run `STOW_ARCHIVE_DIR=\(destination.path) stowmail daemon install` \
            (with your other STOW_ settings), or `STOW_ARCHIVE_DIR= stowmail daemon install` to have it follow the chosen folder.
            """
    }

    /// Runs steps 1 to 5 on `archive`, whose writer lock the caller holds.
    /// `say` gets each line to show, `confirmDelete` the deletion question.
    public static func move(
        _ archive: Archive,
        to destination: URL,
        keys: ArchiveKeys,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        agentEnvironment: [String: String] = LaunchAgent.installedEnvironment(),
        settings: ArchiveSettings = ArchiveSettings(),
        say: @escaping @Sendable (String) -> Void,
        confirmDelete: (String) -> Bool
    ) throws -> Outcome {
        let destination = destination.standardizedFileURL
        let old = archive.location
        if let caution = try ArchiveMover.check(old, destination: destination) { say("Caution: \(caution).") }
        let report = try ArchiveMover.copy(archive, to: destination, keys: keys) { step in say(step + "...") }
        say("The copy verified: \(report.rebuilt) messages rebuilt byte for byte, \(report.attachments) attachments intact.")
        if environment["STOW_ARCHIVE_DIR"].map({ !$0.isEmpty }) ?? false {
            say("STOW_ARCHIVE_DIR is set, so set it to \(destination.path) to use the copy. The old archive was left in place.")
            return .copiedOnly
        }
        let warning = agentWarning(agentEnvironment: agentEnvironment, destination: destination)
        if let warning { say("Warning: " + warning) }

        try old.writeMovedMarker(to: destination, sync: archive.diskSync)
        settings.setChosenFolder(destination.path == ArchiveLocation.defaultForCLI.root.path ? nil : destination)
        say("Stow now uses \(destination.path).")
        try archive.database.close()

        let question = "Delete the old copy at \(old.root.path)? The background sync waits until you answer."
        guard confirmDelete(question) else {
            say("The old copy was kept. You can delete it later; Stow will not open it again.")
            return .moved(deletedOld: false)
        }
        let database = old.databaseURL.path
        for url in [old.databaseURL, URL(fileURLWithPath: database + "-wal"), URL(fileURLWithPath: database + "-shm"),
                    old.rawDirectory, old.attachmentsDirectory, old.recoveryBundleURL,
                    old.root.appendingPathComponent(RecoveryBundle.pendingFileName)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        say("Deleted the old copy. A note saying where it went (moved-to.json) stays in the old folder.")
        return .moved(deletedOld: true)
    }
}
