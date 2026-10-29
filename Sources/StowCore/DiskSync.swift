import Foundation

/// Making a file and its name survive a power cut, in the right order (A-04, A-05, A-11).
///
/// On macOS `fsync` hands a file's bytes to the drive, which may still hold
/// them in its own cache and write them in any order; `F_FULLFSYNC` asks the
/// drive to empty that cache too. A rename or unlink changes the folder, so
/// the folder is flushed after one.
///
/// Every step goes through `observe` first. The real one does nothing; tests
/// pass one that records the order of steps or throws to stop at a step, as a
/// power cut would.
public struct DiskSync: Sendable {
    public enum Step: Sendable, Equatable {
        /// A file's bytes flushed to the drive: `F_FULLFSYNC` when `full`, else `fsync`.
        case flushFile(String, full: Bool)
        /// A folder's entries flushed after a rename or unlink in it.
        case flushFolder(String)
        case rename(from: String, to: String)
        case unlink(String)
        /// A database transaction made durable (SQLite's own full sync).
        case durableCommit
        /// The drive's cache emptied once for several files flushed with `fsync`.
        case barrier
    }

    let observe: @Sendable (Step) throws -> Void

    public init(observe: @escaping @Sendable (Step) throws -> Void) {
        self.observe = observe
    }

    public static let system = DiskSync { _ in }

    /// Flushes an open file. `F_FULLFSYNC` can fail on file systems that lack
    /// it (some network and FAT disks); `fsync` is then the best there is.
    public func flushFile(_ descriptor: Int32, path: String, full: Bool = true) throws {
        try observe(.flushFile(path, full: full))
        if full, fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw DiskSyncError.flushFailed(errno) }
    }

    /// Flushes a folder's entries: `fsync` on the folder itself.
    public func flushFolder(_ folder: URL) throws {
        try observe(.flushFolder(folder.path))
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DiskSyncError.flushFailed(errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw DiskSyncError.flushFailed(errno) }
    }

    /// Renames `source` over `destination` in one step, replacing it if present.
    public func rename(_ source: URL, to destination: URL) throws {
        try observe(.rename(from: source.path, to: destination.path))
        guard Foundation.rename(source.path, destination.path) == 0 else { throw DiskSyncError.renameFailed(errno) }
    }

    /// Empties the drive's cache once, after files were flushed with `fsync`.
    /// Any open file on the same disk will do; `F_FULLFSYNC` acts on the whole drive.
    public func barrier(_ folder: URL) throws {
        try observe(.barrier)
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DiskSyncError.flushFailed(errno) }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw DiskSyncError.flushFailed(errno) }
    }

    /// Records a step done elsewhere (a commit, an unlink), so tests see it in order.
    public func note(_ step: Step) throws {
        try observe(step)
    }
}

public enum DiskSyncError: Error, Equatable, CustomStringConvertible {
    case flushFailed(Int32)
    case renameFailed(Int32)

    public var description: String {
        switch self {
        case .flushFailed(let code): "Could not flush a file to disk (error \(code))."
        case .renameFailed(let code): "Could not rename a file into place (error \(code))."
        }
    }
}
