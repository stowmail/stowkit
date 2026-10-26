import Foundation
import GRDB
import StowCore

public enum EmlExportError: Error, Equatable, CustomStringConvertible {
    /// No such message: removed from Stow (put it back first) or never stored.
    case notInArchive(StoredMessageID)

    public var description: String {
        switch self {
        case .notInArchive: "This email is not in the archive. If it was removed from Stow, put it back first."
        }
    }
}

/// One email as an `.eml` file (D-419, R12): the original message byte for byte
/// as stored (D-005), decrypted, with every header and attachment. Beside
/// `MboxExport`, which writes a whole account.
///
/// The file is written to a temporary name in the destination folder and then
/// renamed (`SafeFile`), so a half-written file never carries the final name,
/// and an existing file is never replaced unless the user agreed in a save panel.
public enum EmlExport {
    /// Writes the stored original of `message` into an open file. Returns the bytes written.
    /// For a writer that cannot see the destination folder (the login item in step 4 gets a
    /// file handle over XPC; the app does the naming and renaming).
    @discardableResult
    public static func write(_ archive: Archive, message: StoredMessageID, to handle: FileHandle) throws -> Int {
        guard let raw = try archive.rawMessage(message) else { throw EmlExportError.notInArchive(message) }
        try handle.write(contentsOf: raw)
        return raw.count
    }

    /// Saves `message` into `folder` as `name` (default `suggestedName`), as " 2", " 3" if
    /// taken. Returns the final URL.
    @discardableResult
    public static func export(_ archive: Archive, message: StoredMessageID, into folder: URL, name: String? = nil) async throws -> URL {
        let fileName = try name ?? suggestedName(archive, message: message)
        // Checked before any file is created, so a removed email leaves nothing behind.
        guard try exists(archive, message) else { throw EmlExportError.notInArchive(message) }
        return try await SafeFile.write(into: folder, name: fileName) { handle in
            try write(archive, message: message, to: handle)
        }
    }

    /// D-419's file name for a stored message, from its date, subject and first From.
    public static func suggestedName(_ archive: Archive, message: StoredMessageID, timeZone: TimeZone = .current) throws -> String {
        let row = try archive.database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT m.internal_date, m.subject, ma.display_name, a.address FROM messages m
                LEFT JOIN message_addresses ma ON ma.message_id = m.id AND ma.role = 'from' AND ma.position = 0
                LEFT JOIN addresses a ON a.id = ma.address_id WHERE m.id = ?
                """, arguments: [message])
        }
        guard let row else { throw EmlExportError.notInArchive(message) }
        let sender = (row["address"] as String?).map { EmailAddress(name: row["display_name"], address: $0) }
        return EmlFileName.make(date: Date(timeIntervalSince1970: TimeInterval(row["internal_date"] as Int64)),
                                subject: row["subject"], sender: sender, timeZone: timeZone)
    }

    static func exists(_ archive: Archive, _ message: StoredMessageID) throws -> Bool {
        try archive.database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE id = ?)", arguments: [message]) ?? false
        }
    }
}
