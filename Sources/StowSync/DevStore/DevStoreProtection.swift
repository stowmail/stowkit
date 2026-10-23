import Foundation

/// Protections for the unencrypted development store (brief step 8, D-015, D-108).
///
/// Real mail sits there as plain `.eml` files until Phase 2 moves to encrypted
/// storage, so before anything is written the folder must be:
/// - excluded from Time Machine (backup drives may not be encrypted);
/// - hidden from Spotlight, which would otherwise index every message's text;
/// - outside iCloud Drive and outside any git repository.
public struct DevStoreProtection: Sendable {
    /// `~/Library/Application Support/Stow/dev-raw.noindex`. The `.noindex`
    /// ending is what reliably keeps Spotlight out on current macOS.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stow/dev-raw.noindex", isDirectory: true)
    }

    /// Where sync keeps its own small state files (the byte budget), outside the store.
    public static var defaultStateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stow/sync-state", isDirectory: true)
    }

    public static let spotlightMarker = ".metadata_never_index"

    /// What `stowmail doctor` reports for the store.
    public struct Status: Sendable, Equatable {
        public var exists: Bool
        public var excludedFromTimeMachine: Bool
        public var spotlightMarkerPresent: Bool
        public var noindexSuffix: Bool
        public var insideGitRepository: Bool
        public var insideICloudDrive: Bool

        /// Human-readable list of what is wrong. Empty means safe to write.
        public var problems: [String] {
            var problems: [String] = []
            if !excludedFromTimeMachine { problems.append("not excluded from Time Machine") }
            if !spotlightMarkerPresent { problems.append("no \(DevStoreProtection.spotlightMarker) file") }
            if !noindexSuffix { problems.append("folder name does not end in .noindex, so Spotlight may index it") }
            if insideGitRepository { problems.append("inside a git repository") }
            if insideICloudDrive { problems.append("inside iCloud Drive") }
            return problems
        }

        public var isProtected: Bool { exists && problems.isEmpty }
    }

    let timeMachine: TimeMachineExclusion

    public init(timeMachine: TimeMachineExclusion = TMUtil()) {
        self.timeMachine = timeMachine
    }

    public func status(of root: URL) -> Status {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
        return Status(
            exists: exists,
            excludedFromTimeMachine: exists && timeMachine.isExcluded(root),
            spotlightMarkerPresent: FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.spotlightMarker).path),
            noindexSuffix: root.pathComponents.contains { $0.hasSuffix(".noindex") },
            insideGitRepository: Self.isInsideGitRepository(root),
            insideICloudDrive: Self.isInsideICloudDrive(root)
        )
    }

    /// Creates the folder (0700) and applies the Time Machine and Spotlight
    /// protections. Refuses locations in a git repository or iCloud Drive, and
    /// folders whose name lacks `.noindex`. Safe to run repeatedly.
    @discardableResult
    public func protect(_ root: URL) throws -> Status {
        let root = root.standardizedFileURL
        var status = status(of: root)
        let locationProblems = status.problems.filter {
            $0.contains("git") || $0.contains("iCloud") || $0.contains(".noindex")
        }
        guard locationProblems.isEmpty else { throw SyncError.devStoreUnprotected(locationProblems) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let marker = root.appendingPathComponent(Self.spotlightMarker)
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw SyncError.devStoreUnprotected(["could not create \(Self.spotlightMarker)"])
            }
        }
        if !timeMachine.isExcluded(root) {
            try timeMachine.exclude(root)
        }
        status = self.status(of: root)
        return status
    }

    /// Throws unless every protection is in place. Sync calls this before writing anything.
    public func requireProtected(_ root: URL) throws {
        let status = status(of: root)
        guard status.exists else { throw SyncError.devStoreUnprotected(["the folder does not exist"]) }
        guard status.problems.isEmpty else { throw SyncError.devStoreUnprotected(status.problems) }
    }

    static func isInsideGitRepository(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    static func isInsideICloudDrive(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/Library/Mobile Documents") || path.hasPrefix(home + "/Library/CloudStorage") {
            return true
        }
        // Desktop and Documents may be synced by iCloud; ask the system about the nearest existing folder.
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true
    }
}

/// Time Machine exclusion, behind a protocol so tests do not touch real settings.
public protocol TimeMachineExclusion: Sendable {
    func isExcluded(_ url: URL) -> Bool
    func exclude(_ url: URL) throws
}

/// Uses `/usr/bin/tmutil`. `addexclusion` without `-p` sets a sticky
/// exclusion that travels with the folder and needs no administrator rights.
public struct TMUtil: TimeMachineExclusion {
    public init() {}

    public func isExcluded(_ url: URL) -> Bool {
        guard let output = try? Self.run(["isexcluded", url.path]) else { return false }
        return output.contains("[Excluded]")
    }

    public func exclude(_ url: URL) throws {
        _ = try Self.run(["addexclusion", url.path])
        guard isExcluded(url) else {
            throw SyncError.devStoreUnprotected(["tmutil could not exclude the folder from Time Machine"])
        }
    }

    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
