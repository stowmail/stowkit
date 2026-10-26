import Foundation

public enum SafeFileError: Error, Equatable, CustomStringConvertible {
    case notAFolder(String)
    case cannotCreate(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notAFolder(let path): "\(path) is not a folder. Choose a folder to save into."
        case .cannotCreate(let path): "Could not create a file in \(path). Check that the folder exists and you can write to it."
        case .writeFailed(let path): "Could not finish writing into \(path). Nothing was saved under the final name."
        }
    }
}

/// Writing a file the user asked for without ever leaving a half-written file
/// under its final name (D-419): the bytes go to a temporary name in the same
/// folder (created with `O_EXCL` and `O_NOFOLLOW`, permissions 0600), are
/// flushed to disk, and only then is the file renamed. The rename never
/// replaces an existing file unless the caller says the user agreed to it.
///
/// Used by `EmlExport` in the engine and by the app's Save as Email File, so
/// both follow one rule.
public enum SafeFile {
    /// The temporary name: hidden, and never the final name.
    static func temporaryName() -> String {
        ".stow-\(UUID().uuidString.lowercased()).part"
    }

    /// Writes through `write` into a temporary file in `folder`, then names it `name`,
    /// adding " 2", " 3" before the extension if that name is taken. Returns the final URL.
    /// On any failure the temporary file is removed and nothing carries `name`.
    public static func write(into folder: URL, name: String, _ write: @Sendable (FileHandle) async throws -> Void) async throws -> URL {
        let temporary = try await writeTemporary(in: folder, write)
        do {
            return try publish(temporary, in: folder, as: name)
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// As `write(into:name:_:)`, for a destination the user picked in a save panel. With
    /// `replacing` (the panel asked and the user agreed) an existing file there is replaced
    /// in one step; without it an existing file is kept and a numbered name is used.
    public static func write(to destination: URL, replacing: Bool, _ write: @Sendable (FileHandle) async throws -> Void) async throws -> URL {
        let folder = destination.deletingLastPathComponent()
        let temporary = try await writeTemporary(in: folder, write)
        do {
            if replacing {
                guard rename(temporary.path, destination.path) == 0 else { throw SafeFileError.writeFailed(folder.path) }
                return destination
            }
            return try publish(temporary, in: folder, as: destination.lastPathComponent)
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// Creates the temporary file, lets `write` fill it, and flushes it to disk.
    static func writeTemporary(in folder: URL, _ write: @Sendable (FileHandle) async throws -> Void) async throws -> URL {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw SafeFileError.notAFolder(folder.path)
        }
        let temporary = folder.appendingPathComponent(temporaryName(), isDirectory: false)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SafeFileError.cannotCreate(folder.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try await write(handle)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error is SafeFileError ? error : SafeFileError.writeFailed(folder.path)
        }
        return temporary
    }

    /// Renames `temporary` to `name` in `folder` without replacing anything: `RENAME_EXCL`
    /// fails if the name exists, so a file appearing meanwhile is never overwritten.
    static func publish(_ temporary: URL, in folder: URL, as name: String) throws -> URL {
        for number in 1...999 {
            let candidate = folder.appendingPathComponent(numbered(name, number), isDirectory: false)
            if renamex_np(temporary.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { throw SafeFileError.writeFailed(folder.path) }
        }
        throw SafeFileError.writeFailed(folder.path)
    }

    /// `Invoice.eml`, then `Invoice 2.eml`, `Invoice 3.eml` (D-419).
    public static func numbered(_ name: String, _ number: Int) -> String {
        guard number > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        return ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
    }
}

/// The name Save as Email File suggests (D-419): `<YYYY-MM-DD> <subject>, <sender name>.eml`,
/// with characters a file name cannot hold replaced and the whole trimmed to 120 characters.
public enum EmlFileName {
    public static let maxLength = 120

    /// `date` is the message's date as the list shows it (`internal_date`), as a day in
    /// `timeZone`; `sender` is the From name, else its address.
    public static func make(date: Date, subject: String?, sender: EmailAddress?, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let prefix = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let subjectText = clean(subject ?? "")
        let senderText = clean(sender.map { ($0.name?.isEmpty == false ? $0.name! : $0.address) } ?? "")
        var stem = prefix + " " + (subjectText.isEmpty ? "No subject" : subjectText)
        if !senderText.isEmpty { stem += ", " + senderText }
        let ext = ".eml"
        if stem.count + ext.count > maxLength {
            stem = String(stem.prefix(maxLength - ext.count)).trimmingCharacters(in: .whitespaces)
        }
        return stem + ext
    }

    /// Path separators, Finder's colon and control characters become a dash; runs of
    /// whitespace become one space; no leading dot, so the file is never hidden.
    static func clean(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !result.hasSuffix(" ") { result += " " }
            } else if scalar == "/" || scalar == ":" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) {
                result.unicodeScalars.append("-")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        result = result.trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(".") { result.removeFirst() }
        return result
    }
}
