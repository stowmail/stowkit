import Foundation

public enum ArchiveLocationError: Error, Equatable, CustomStringConvertible {
    /// The folder is inside iCloud Drive or another cloud-synced folder (D-203).
    case cloudSynced(String)
    case cannotSecure(String)

    public var description: String {
        switch self {
        case .cloudSynced(let reason):
            "The archive cannot live in a cloud-synced folder (\(reason)). Choose a local folder."
        case .cannotSecure(let path):
            "Could not restrict permissions on \(path) to the owner"
        }
    }
}

/// Where the archive lives on disk, and the layout inside it:
///
/// ```
/// archive.sqlite (+ -wal, -shm)    encrypted database
/// raw/<2 hex>/<hash hex>           raw messages, LZFSE then AES-GCM
/// attachments/<2 hex>/<hash hex>   attachments, AES-GCM
/// ```
///
/// Every folder is created with permissions 0700 (owner only) and every file
/// 0600. The archive is included in Time Machine (it is encrypted) and is never
/// allowed inside iCloud Drive or another cloud-synced folder (D-203).
public struct ArchiveLocation: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `~/Library/Application Support/Stow/` for the CLI. The Phase 5 app uses its container instead.
    public static var defaultForCLI: ArchiveLocation {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ArchiveLocation(root: support.appendingPathComponent("Stow", isDirectory: true))
    }

    /// The location from `STOW_ARCHIVE_DIR` if set, else the CLI default.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ArchiveLocation {
        if let path = environment["STOW_ARCHIVE_DIR"], !path.isEmpty {
            return ArchiveLocation(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        }
        return defaultForCLI
    }

    public var databaseURL: URL { root.appendingPathComponent("archive.sqlite") }
    public var rawDirectory: URL { root.appendingPathComponent("raw", isDirectory: true) }
    public var attachmentsDirectory: URL { root.appendingPathComponent("attachments", isDirectory: true) }

    public var exists: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    /// Creates the folders (0700) after checking the location is not cloud-synced.
    /// Also tightens permissions on folders that already exist.
    public func prepare() throws {
        try Self.refuseCloudSynced(root)
        for directory in [root, rawDirectory, attachmentsDirectory] {
            try Self.makeDirectory(directory)
        }
        // Spotlight would only see encrypted bytes, but indexing them wastes effort.
        let marker = root.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw ArchiveLocationError.cannotSecure(url.lastPathComponent)
        }
    }

    /// Refuses iCloud Drive (`~/Library/Mobile Documents`), File Provider
    /// folders such as Dropbox, OneDrive and Google Drive (`~/Library/CloudStorage`),
    /// and any folder macOS reports as ubiquitous (for example Desktop and
    /// Documents when "Desktop & Documents Folders" sync is on).
    static func refuseCloudSynced(_ url: URL) throws {
        let path = url.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        for (folder, reason) in [("Library/Mobile Documents", "iCloud Drive"), ("Library/CloudStorage", "cloud storage provider")] {
            let blocked = (home as NSString).appendingPathComponent(folder)
            if path == blocked || path.hasPrefix(blocked + "/") { throw ArchiveLocationError.cloudSynced(reason) }
        }
        // Walk up to the nearest existing folder and ask macOS whether it syncs.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        if let values = try? probe.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
            throw ArchiveLocationError.cloudSynced("iCloud")
        }
    }
}
