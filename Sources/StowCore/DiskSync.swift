import Foundation

/// Making a file and its name survive a power cut, in the right order (A-04, A-05, A-11).
///
/// On macOS `fsync` hands a file's bytes to the drive, which may still hold
/// them in its own cache and write them in any order; `F_FULLFSYNC` asks the
/// drive to empty that cache too, which is slow (milliseconds per call).
/// `F_BARRIERFSYNC` hands the bytes over and puts a barrier after them, so
/// nothing written later reaches the disk before them: the order is kept
/// without emptying the cache. A rename or unlink changes the folder, so the
/// folder is flushed after one.
///
/// Every step goes through `observe` first. The real one does nothing; tests
/// pass one that records the order of steps or throws to stop at a step, as a
/// power cut would.
public struct DiskSync: Sendable {
    /// How far a flush goes.
    public enum Flush: Sendable, Equatable {
        /// Out of the drive's cache and onto the disk: `F_FULLFSYNC`.
        case full
        /// Ahead of anything written later: `F_BARRIERFSYNC`.
        case ordered
        /// Handed to the drive only: `fsync`. Needs a `barrier` before anything
        /// that must come after it.
        case handedOver
    }

    public enum Step: Sendable, Equatable {
        /// A file's bytes flushed to the drive.
        case flushFile(String, Flush)
        /// A folder's entries flushed after a rename or unlink in it.
        case flushFolder(String, Flush)
        case rename(from: String, to: String)
        case unlink(String)
        /// A database transaction made durable (SQLite's own full sync).
        case durableCommit
        /// A database transaction committed, durable or not.
        case commit
        /// A barrier after several files handed over with `fsync`.
        case barrier
    }

    let observe: @Sendable (Step) throws -> Void

    public init(observe: @escaping @Sendable (Step) throws -> Void) {
        self.observe = observe
    }

    public static let system = DiskSync { _ in }

    /// Flushes an open file.
    public func flushFile(_ descriptor: Int32, path: String, _ flush: Flush = .full) throws {
        try observe(.flushFile(path, flush))
        try Self.flush(descriptor, flush)
    }

    /// Flushes a folder's entries. `.full` is a plain `fsync` of the folder:
    /// the file inside it had the full flush.
    public func flushFolder(_ folder: URL, _ flush: Flush = .full) throws {
        try observe(.flushFolder(folder.path, flush))
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DiskSyncError.flushFailed(errno) }
        defer { close(descriptor) }
        if flush == .ordered, fcntl(descriptor, F_BARRIERFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw DiskSyncError.flushFailed(errno) }
    }

    /// `fsync`, `F_FULLFSYNC` or `F_BARRIERFSYNC`; either can fail on file systems that
    /// lack it (some network and FAT disks). A barrier that fails falls back to
    /// the full flush, which keeps the order too; `fsync` is the last resort.
    static func flush(_ descriptor: Int32, _ flush: Flush) throws {
        if flush == .handedOver {
            guard fsync(descriptor) == 0 else { throw DiskSyncError.flushFailed(errno) }
            return
        }
        if flush == .ordered, fcntl(descriptor, F_BARRIERFSYNC) == 0 { return }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw DiskSyncError.flushFailed(errno) }
    }

    /// Renames `source` over `destination` in one step, replacing it if present.
    public func rename(_ source: URL, to destination: URL) throws {
        try observe(.rename(from: source.path, to: destination.path))
        guard Foundation.rename(source.path, destination.path) == 0 else { throw DiskSyncError.renameFailed(errno) }
    }

    /// One barrier after files and folders were handed over with `fsync`: the
    /// drive writes everything already handed to it before anything after the
    /// barrier. It acts on the whole drive, so any folder on it will do.
    public func barrier(_ folder: URL) throws {
        try observe(.barrier)
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DiskSyncError.flushFailed(errno) }
        defer { close(descriptor) }
        try Self.flush(descriptor, .ordered)
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
