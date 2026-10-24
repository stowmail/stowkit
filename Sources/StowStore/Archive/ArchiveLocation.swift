import Foundation

public enum ArchiveLocationError: Error, Equatable, CustomStringConvertible {
    /// The folder is inside iCloud Drive or another cloud-synced folder (D-203).
    case cloudSynced(String)
    case cannotSecure(String)
    /// The volume type cannot hold an archive safely (D-023, D-035).
    case unsupportedVolume(String)
    /// The chosen archive folder is not there, usually because its disk is
    /// disconnected. Nothing is written anywhere else meanwhile.
    case offline(String)

    public var description: String {
        switch self {
        case .cloudSynced(let reason):
            "The archive cannot live in a cloud-synced folder (\(reason)). Choose a local folder."
        case .cannotSecure(let path):
            "Could not restrict permissions on \(path) to the owner"
        case .unsupportedVolume(let reason):
            "The archive cannot live there: \(reason)."
        case .offline(let path):
            "Archive offline: \(path) is not available. If it is on an external disk, connect the disk. Sync is paused until then."
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

    /// The location to use: `STOW_ARCHIVE_DIR` if set (development and
    /// tests), else the folder the user chose (D-035), else the CLI default.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: ArchiveSettings = ArchiveSettings()
    ) -> ArchiveLocation {
        if let path = environment["STOW_ARCHIVE_DIR"], !path.isEmpty {
            return ArchiveLocation(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let chosen = settings.chosenFolder { return ArchiveLocation(root: chosen) }
        return defaultForCLI
    }

    /// The recovery bundle beside the database (D-031).
    public var recoveryBundleURL: URL { root.appendingPathComponent("keys.recovery") }
    var lockURL: URL { root.appendingPathComponent(".writer.lock") }

    /// Throws `offline` when the archive's database is not there although the
    /// folder was chosen (or found) before: never creates a new archive in its
    /// place, since on a disconnected disk that would land on the startup disk.
    public func requireOnline() throws {
        guard exists else { throw ArchiveLocationError.offline(root.path) }
    }

    // MARK: - Volume (D-023, D-035)

    /// What kind of disk a folder is on, and whether an archive may live there.
    public struct VolumeInfo: Sendable, Equatable {
        /// For example `apfs`, `hfs`, `exfat`, `smbfs`.
        public var fileSystem: String
        public var isLocal: Bool
        public var verdict: Verdict

        public enum Verdict: Sendable, Equatable {
            case suitable
            /// Allowed, with this caution shown to the user.
            case warning(String)
            /// Not allowed, for this reason.
            case refused(String)
        }
    }

    /// Checks the volume a folder is (or would be) on: APFS and Mac OS
    /// Extended are suitable; exFAT is allowed with a warning; network shares,
    /// FAT and anything else are refused, as are cloud-synced folders.
    public static func checkVolume(_ url: URL) -> VolumeInfo {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        var info = statfs()
        guard statfs(probe.path, &info) == 0 else {
            return VolumeInfo(fileSystem: "unknown", isLocal: false, verdict: .refused("the disk could not be read"))
        }
        let fileSystem = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let isLocal = info.f_flags & UInt32(MNT_LOCAL) != 0
        let verdict: VolumeInfo.Verdict
        if (try? refuseCloudSynced(url)) == nil {
            verdict = .refused("cloud-synced folders copy the database mid-write and put mail back in a provider's cloud")
        } else if !isLocal || ["smbfs", "afpfs", "nfs", "webdav", "cifs", "ftp"].contains(fileSystem) {
            verdict = .refused("network shares and NAS are not supported, because database locking is unreliable over a network")
        } else {
            switch fileSystem {
            case "apfs", "hfs":
                verdict = .suitable
            case "exfat":
                verdict = .warning("exFAT keeps no journal, so unplugging the disk while Stow writes can damage the archive. APFS or Mac OS Extended is safer")
            case "msdos":
                verdict = .refused("FAT disks cannot hold files over 4 GB, and the database will grow past that")
            default:
                verdict = .refused("\(fileSystem) disks are not supported; use APFS or Mac OS Extended")
            }
        }
        return VolumeInfo(fileSystem: fileSystem, isLocal: isLocal, verdict: verdict)
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

/// Where the user's chosen archive folder is remembered (D-035): the
/// `ee.getstow.stow` preferences domain. The path is not secret. The app
/// (Phase 5) keeps a security-scoped bookmark instead.
public struct ArchiveSettings: @unchecked Sendable {
    static let key = "archiveFolder"
    let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: "ee.getstow.stow") ?? .standard) {
        self.defaults = defaults
    }

    /// The chosen folder, or nil for the default.
    public var chosenFolder: URL? {
        defaults.string(forKey: Self.key).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    public func setChosenFolder(_ url: URL?) {
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}

public enum ArchiveLockError: Error, Equatable, CustomStringConvertible {
    case busy
    case cannotOpen

    public var description: String {
        switch self {
        case .busy: "Another Stow process (probably the background sync) is writing to the archive. Try again in a moment."
        case .cannotOpen: "Could not open the archive's lock file"
        }
    }
}

/// One writer at a time (D-035): sync, import, tidy-up, moves and the daemon's
/// turns each hold this lock on the archive folder while they write. Readers
/// (search, stats) need no lock. Released when the process ends, even if it crashes.
public final class ArchiveLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Takes the lock, waiting up to `wait` seconds (nil: do not wait).
    /// `onWait` runs once if it has to wait.
    public static func acquire(_ location: ArchiveLocation, wait: TimeInterval? = nil, onWait: (() -> Void)? = nil) throws -> ArchiveLock {
        let descriptor = open(location.lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ArchiveLockError.cannotOpen }
        let deadline = Date().addingTimeInterval(wait ?? 0)
        var waited = false
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, let wait, wait > 0, Date() < deadline else {
                close(descriptor)
                throw ArchiveLockError.busy
            }
            if !waited {
                waited = true
                onWait?()
            }
            usleep(250_000)
        }
        return ArchiveLock(descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
