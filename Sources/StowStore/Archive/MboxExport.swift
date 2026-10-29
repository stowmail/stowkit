import Foundation
import GRDB
import StowCore

public enum MboxExportError: Error, Equatable, CustomStringConvertible {
    case destinationExists(String)
    case cannotCreate(String)
    case notAFolder(String)

    public var description: String {
        switch self {
        case .destinationExists(let path): "\(path) already exists. Choose a new file name."
        case .cannotCreate(let path): "Could not create \(path)"
        case .notAFolder(let path): "\(path) is a file, not a folder. Choose a folder to export into."
        }
    }
}

/// One account's file written by "Export everything" (D-068, D-406).
public struct AccountExport: Sendable, Equatable {
    public var account: AccountID
    public var file: URL
    public var messages: Int
    public var bytes: Int
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
    ///
    /// Written under a hidden temporary name in the same folder, flushed, then
    /// renamed to `url` without replacing anything (`RENAME_EXCL`), as
    /// `SafeFile` does (A-20). An error part way (a missing or damaged stored
    /// file, a full disk) removes the temporary file, so nothing is left under
    /// `url` and the retry works. A name that appears meanwhile is never
    /// overwritten and gives `destinationExists`. A temporary file left by a
    /// killed process is hidden (`.stow-….part`) and never blocks a retry.
    @discardableResult
    public static func export(
        _ archive: Archive, account: AccountID, to url: URL, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> (messages: Int, bytes: Int) {
        try export(archive, account: account, to: url, progress: progress, beforePublishing: {})
    }

    /// `export`, with a step tests use to take the name before the rename.
    static func export(
        _ archive: Archive, account: AccountID, to url: URL, progress: (@Sendable (Int, Int) -> Void)?,
        beforePublishing: () -> Void
    ) throws -> (messages: Int, bytes: Int) {
        var status = stat()
        if lstat(url.path, &status) == 0 { throw MboxExportError.destinationExists(url.path) }
        let temporary: URL
        let handle: FileHandle
        do {
            (temporary, handle) = try SafeFile.openTemporary(in: url.deletingLastPathComponent())
        } catch SafeFileError.notAFolder(let path) {
            throw MboxExportError.notAFolder(path)
        } catch {
            throw MboxExportError.cannotCreate(url.path)
        }
        do {
            let written = try write(archive, account: account, into: handle, progress: progress)
            try handle.close()
            beforePublishing()
            guard try SafeFile.publishExclusively(temporary, as: url) else { throw MboxExportError.destinationExists(url.path) }
            return written
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error
        }
    }

    /// Every message of `account`, oldest first, into `handle`, then flushed.
    private static func write(
        _ archive: Archive, account: AccountID, into handle: FileHandle, progress: (@Sendable (Int, Int) -> Void)?
    ) throws -> (messages: Int, bytes: Int) {
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

    /// "Export everything" (D-068): one mboxrd file per account in `folder`,
    /// each exactly what `export` writes for that account, named from the
    /// account's address (`fileName(for:)`). Every account in the archive,
    /// connected or not. The folder is created (0700) if missing. Refuses before
    /// writing anything if any of the files already exists. The engine has no
    /// licence state: this works whatever the app's licence says.
    /// `progress` gets the account, then messages done and that account's total.
    @discardableResult
    public static func exportAll(
        _ archive: Archive, to folder: URL, progress: (@Sendable (AccountID, Int, Int) -> Void)? = nil
    ) throws -> [AccountExport] {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { throw MboxExportError.notAFolder(folder.path) }
        } else {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw MboxExportError.cannotCreate(folder.path)
            }
        }
        // Straight from the table, so an account whose provider this build does not know is exported too.
        let accounts = try archive.database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, email FROM accounts ORDER BY created_at, id").map {
                (AccountID(rawValue: $0["id"]), $0["email"] as String)
            }
        }
        var used: Set<String> = []
        let planned = accounts.map { account, email -> (AccountID, URL) in
            let base = fileName(for: email, fallback: account.rawValue)
            var name = base + ".mbox"
            var number = 2
            // APFS is usually case-insensitive: compare names without case.
            while used.contains(name.lowercased()) {
                name = "\(base)-\(number).mbox"
                number += 1
            }
            used.insert(name.lowercased())
            return (account, folder.appendingPathComponent(name, isDirectory: false))
        }
        for (_, url) in planned {
            var status = stat()
            if lstat(url.path, &status) == 0 { throw MboxExportError.destinationExists(url.path) }
        }
        var results: [AccountExport] = []
        for (account, url) in planned {
            var perAccount: (@Sendable (Int, Int) -> Void)?
            if let progress { perAccount = { done, total in progress(account, done, total) } }
            let result = try export(archive, account: account, to: url, progress: perAccount)
            results.append(AccountExport(account: account, file: url, messages: result.messages, bytes: result.bytes))
        }
        return results
    }

    /// A file name (without `.mbox`) from an account's address: lowercased,
    /// anything but letters, digits and `@ . _ - +` replaced by `_`, no leading
    /// dot, at most 200 characters; `fallback` if nothing is left.
    public static func fileName(for address: String, fallback: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789@._-+")
        var name = String(address.trimmingCharacters(in: .whitespaces).lowercased().map { allowed.contains($0) ? $0 : "_" })
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(200))
        return name.isEmpty ? fallback : name
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
