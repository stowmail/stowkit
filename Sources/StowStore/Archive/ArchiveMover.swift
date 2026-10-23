import Foundation
import GRDB
import StowSecrets

public enum ArchiveMoveError: Error, Equatable, CustomStringConvertible {
    case destinationNotEmpty(String)
    case destinationInsideArchive
    case unsupportedVolume(String)
    case copyFailedVerification

    public var description: String {
        switch self {
        case .destinationNotEmpty(let path): "\(path) is not empty. Choose an empty or new folder."
        case .destinationInsideArchive: "The new folder cannot be inside the current archive."
        case .unsupportedVolume(let reason): "The archive cannot move there: \(reason)."
        case .copyFailedVerification: "The copy did not verify, so the archive was not moved. The original is untouched."
        }
    }
}

/// Copies the archive to a new folder and checks the copy (D-023, D-035):
/// the database with SQLite's online backup (a consistent copy, still
/// encrypted with the same key), then the encrypted message and attachment
/// files, then a full `ArchiveVerifier` run on the copy. The caller switches
/// to the copy only if it is clean; the original is never changed.
public enum ArchiveMover {
    /// What may go into a new archive folder: nothing yet, or only Finder's leftovers.
    static let ignorable: Set<String> = [".DS_Store"]

    /// Checks `destination` can take the archive. Returns any volume warning to show.
    public static func check(_ source: ArchiveLocation, destination: URL) throws -> String? {
        let destination = destination.standardizedFileURL
        if destination.path == source.root.path || destination.path.hasPrefix(source.root.path + "/") {
            throw ArchiveMoveError.destinationInsideArchive
        }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: destination.path),
           contents.contains(where: { !ignorable.contains($0) }) {
            throw ArchiveMoveError.destinationNotEmpty(destination.path)
        }
        switch ArchiveLocation.checkVolume(destination).verdict {
        case .suitable: return nil
        case .warning(let caution): return caution
        case .refused(let reason): throw ArchiveMoveError.unsupportedVolume(reason)
        }
    }

    /// Copies `archive` into `destination` and verifies the copy. Throws if the
    /// copy does not verify; returns the verification report otherwise.
    public static func copy(
        _ archive: Archive, to destination: URL, keys: ArchiveKeys, progress: (@Sendable (String) -> Void)? = nil
    ) throws -> ArchiveVerifyReport {
        let target = ArchiveLocation(root: destination)
        _ = try check(archive.location, destination: destination)
        try target.prepare()

        progress?("Copying the database")
        let copy = try EncryptedDatabase.open(at: target.databaseURL, key: keys.databaseKeyData)
        try archive.database.backup(to: copy)
        try copy.close()
        Archive.secureDatabaseFiles(target)

        progress?("Copying message and attachment files")
        for (from, to) in [(archive.location.rawDirectory, target.rawDirectory), (archive.location.attachmentsDirectory, target.attachmentsDirectory)] {
            try copyContents(of: from, into: to)
        }
        if FileManager.default.fileExists(atPath: archive.location.recoveryBundleURL.path) {
            try FileManager.default.copyItem(at: archive.location.recoveryBundleURL, to: target.recoveryBundleURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.recoveryBundleURL.path)
        }

        progress?("Verifying the copy")
        let opened = try Archive.open(target, keys: keys)
        let report = try ArchiveVerifier(archive: opened).run()
        try opened.database.close()
        guard report.isClean, report.messages == (try archive.database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") }) else {
            throw ArchiveMoveError.copyFailedVerification
        }
        return report
    }

    /// Copies every file below `source` into `destination`, keeping the
    /// two-character subfolders, with folders 0700 and files 0600.
    static func copyContents(of source: URL, into destination: URL) throws {
        let manager = FileManager.default
        // Relative paths straight from the enumerator: a URL enumerator may report
        // /private/var/... for /var/..., which would break prefix arithmetic.
        guard let enumerator = manager.enumerator(atPath: source.path) else { return }
        while let relative = enumerator.nextObject() as? String {
            let from = source.appendingPathComponent(relative)
            let target = destination.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try ArchiveLocation.makeDirectory(target)
            } else if !from.lastPathComponent.hasPrefix(".tmp-") {
                try manager.copyItem(at: from, to: target)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
        }
    }
}
