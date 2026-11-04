import Foundation

public enum MboxFileError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case notAFile(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .missing(let path): "\(path) does not exist."
        case .notAFile(let path): "\(path) is not a file. Name the .mbox file itself (Google Takeout puts it in a Mail folder)."
        case .unreadable(let path): "\(path) cannot be read."
        }
    }
}

/// What reading a whole mbox file found, without importing anything
/// (`stowmail import mbox --check`). Counts only, never content.
public struct MboxScanReport: Sendable, Equatable {
    public var fileBytes: Int64
    public var variant: MboxVariant
    public var counts: MboxReadCounts
    /// Bytes of the messages once the framing is undone.
    public var messageBytes: Int64

    public init(fileBytes: Int64, variant: MboxVariant, counts: MboxReadCounts, messageBytes: Int64) {
        self.fileBytes = fileBytes
        self.variant = variant
        self.counts = counts
        self.messageBytes = messageBytes
    }
}

/// Reading an mbox file from start to end with `MboxReader` (D-559). Reads
/// the local file only; opens no connection (D-109).
public enum MboxScan {
    /// The file's size, after checking it is a regular file that can be read.
    /// A pipe or a folder is refused, so reading never waits for input.
    public static func checkFile(_ url: URL) throws -> Int64 {
        var status = stat()
        guard stat(url.path, &status) == 0 else {
            throw errno == ENOENT ? MboxFileError.missing(url.path) : MboxFileError.unreadable(url.path)
        }
        guard status.st_mode & S_IFMT == S_IFREG else { throw MboxFileError.notAFile(url.path) }
        guard access(url.path, R_OK) == 0 else { throw MboxFileError.unreadable(url.path) }
        return Int64(status.st_size)
    }

    /// Reads every message once. `progress` gets the counts every 10,000 messages.
    public static func scan(
        _ url: URL, variant: MboxVariant = .mboxrd, progress: ((MboxReadCounts) -> Void)? = nil
    ) throws -> MboxScanReport {
        let size = try checkFile(url)
        var reader = MboxReader(try MboxFile(url: url), variant: variant)
        var messageBytes: Int64 = 0
        while let message = try autoreleasepool(invoking: { try reader.next() }) {
            messageBytes += Int64(message.size)
            if let progress, reader.counts.messages % 10_000 == 0 { progress(reader.counts) }
        }
        return MboxScanReport(fileBytes: size, variant: variant, counts: reader.counts, messageBytes: messageBytes)
    }
}
