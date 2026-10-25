import Foundation
import GRDB
import StowCore

public enum MboxExportError: Error, Equatable, CustomStringConvertible {
    case destinationExists(String)
    case cannotCreate(String)

    public var description: String {
        switch self {
        case .destinationExists(let path): "\(path) already exists. Choose a new file name."
        case .cannotCreate(let path): "Could not create \(path)"
        }
    }
}

/// Writes an account's mail as one mbox file (D-042), so nothing is locked
/// into Stow: Apple Mail, Thunderbird and most mail tools can import it.
///
/// The format is mboxrd: each message starts with a `From ` line, and any
/// line in a message that starts with `From ` (after any number of `>`) gets
/// one more `>`, which readers take off again. Messages are written exactly as
/// downloaded, line endings included, rebuilt from the archive's files, except
/// that a message not ending in a line break gains one: mbox cannot say a
/// message ended without one. Oldest first. (The archive itself keeps the exact bytes.)
public enum MboxExport {
    /// Writes the file (permissions 0600, never over an existing file).
    /// Returns the number of messages and bytes written.
    @discardableResult
    public static func export(
        _ archive: Archive, account: AccountID, to url: URL, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> (messages: Int, bytes: Int) {
        // One exclusive create: never over a file, or through a link, that appears in the meantime.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? MboxExportError.destinationExists(url.path) : MboxExportError.cannotCreate(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        let rows = try archive.database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT raw_hash, raw_state, internal_date FROM messages WHERE account_id = ? ORDER BY internal_date, id
                """, arguments: [account.rawValue])
        }
        var bytes = 0
        for (index, row) in rows.enumerated() {
            try autoreleasepool {
                let raw = try archive.rawMessage(hash: row["raw_hash"], state: row["raw_state"])
                let date = Date(timeIntervalSince1970: TimeInterval(row["internal_date"] as Int64))
                let entry = entry(raw, date: date)
                try handle.write(contentsOf: entry)
                bytes += entry.count
            }
            if let progress, (index + 1) % 500 == 0 { progress(index + 1, rows.count) }
        }
        try handle.synchronize()
        return (rows.count, bytes)
    }

    /// One mbox entry: the `From ` line, the quoted message, and a blank line.
    static func entry(_ message: Data, date: Date) -> Data {
        var output = Data("From MAILER-DAEMON \(asctime(date))\n".utf8)
        output.append(quote(message))
        if message.last != 0x0A { output.append(0x0A) }
        output.append(0x0A)
        return output
    }

    /// Adds one `>` to every line starting with `>*From ` (mboxrd).
    static func quote(_ message: Data) -> Data {
        let bytes = [UInt8](message)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count + 64)
        var lineStart = 0
        while lineStart < bytes.count {
            var probe = lineStart
            while probe < bytes.count, bytes[probe] == UInt8(ascii: ">") { probe += 1 }
            if bytes.count - probe >= 5, bytes[probe..<(probe + 5)].elementsEqual("From ".utf8) {
                output.append(UInt8(ascii: ">"))
            }
            let lineEnd = MIMEParser.nextLineFeed(bytes, from: lineStart, to: bytes.count)
            let next = min(lineEnd + 1, bytes.count)
            output += bytes[lineStart..<next]
            lineStart = next
        }
        return Data(output)
    }

    /// The date as `asctime` writes it, in UTC: `Thu Oct 23 09:27:00 2026`.
    static func asctime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.weekday, .month, .day, .hour, .minute, .second, .year], from: date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "%@ %@ %2d %02d:%02d:%02d %d", days[c.weekday! - 1], months[c.month! - 1],
                      c.day!, c.hour!, c.minute!, c.second!, c.year!)
    }
}
