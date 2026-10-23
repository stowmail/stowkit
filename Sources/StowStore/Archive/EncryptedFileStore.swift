import CryptoKit
import Foundation
import StowSecrets

public enum EncryptedFileError: Error, Equatable, CustomStringConvertible {
    case notAStowFile
    case unsupportedVersion(UInt8)
    /// Wrong key, a damaged file, or a file moved to a different name.
    case authenticationFailed
    case decompressionFailed
    case missing

    public var description: String {
        switch self {
        case .notAStowFile: "Not a Stow archive file"
        case .unsupportedVersion(let version): "Unsupported archive file version \(version)"
        case .authenticationFailed: "Archive file failed authentication (wrong key, damaged, or renamed)"
        case .decompressionFailed: "Archive file could not be decompressed"
        case .missing: "Archive file is missing"
        }
    }
}

/// Encrypted, content-addressed files: raw messages and attachments (D-003, D-005, D-202).
///
/// - **Name:** HMAC-SHA256 of the plaintext with the file naming key, in hex,
///   under a two-character subfolder. Someone holding the folder cannot tell
///   whether a known document is present, which a plain SHA-256 would reveal.
/// - **Format:** `STOW` magic, a version byte, a flags byte (bit 0: LZFSE
///   compressed), then AES-256-GCM `nonce | ciphertext | tag`. The header and
///   the file's own hash are authenticated data, so a file renamed or swapped
///   with another fails to open rather than returning the wrong content.
/// - **Writes** happen once: a file that already exists is left alone, which
///   is what makes attachments deduplicate. Written to a temporary name with
///   permissions 0600, then renamed into place.
public struct EncryptedFileStore: Sendable {
    public enum Kind: Sendable {
        case raw
        case attachment
    }

    static let magic: [UInt8] = Array("STOW".utf8)
    static let version: UInt8 = 1
    static let flagCompressed: UInt8 = 1

    public let directory: URL
    public let kind: Kind
    let encryptionKey: SymmetricKey
    let namingKey: SymmetricKey

    public init(directory: URL, kind: Kind, keys: ArchiveKeys) {
        self.directory = directory
        self.kind = kind
        encryptionKey = keys.fileEncryptionKey
        namingKey = keys.fileNamingKey
    }

    /// The keyed hash that names this content.
    public func hash(of content: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: content, using: namingKey))
    }

    public func url(for hash: Data) -> URL {
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(hex)
    }

    public func exists(_ hash: Data) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    /// Stores `content` under `hash` unless it is already there.
    /// Returns the size on disk, and whether this call wrote it.
    @discardableResult
    public func write(_ content: Data, hash: Data) throws -> (storedSize: Int, written: Bool) {
        let destination = url(for: hash)
        if let size = Self.fileSize(destination) { return (size, false) }
        let file = try seal(content, hash: hash)
        let written = try place(file, at: destination, overwrite: false)
        return (written ? file.count : Self.fileSize(destination) ?? file.count, written)
    }

    func seal(_ content: Data, hash: Data) throws -> Data {
        var flags: UInt8 = 0
        var payload = content
        if kind == .raw {
            payload = try (content as NSData).compressed(using: .lzfse) as Data
            flags |= Self.flagCompressed
        }
        let header = Self.magic + [Self.version, flags]
        let sealed = try AES.GCM.seal(payload, using: encryptionKey, authenticating: Data(header) + hash)
        guard let combined = sealed.combined else { throw EncryptedFileError.authenticationFailed }
        return Data(header) + combined
    }

    /// Writes to a temporary file (0600) in the same folder, then renames it into place.
    /// Without `overwrite`, an existing file wins and this returns false.
    private func place(_ file: Data, at destination: URL, overwrite: Bool) throws -> Bool {
        let folder = destination.deletingLastPathComponent()
        try ArchiveLocation.makeDirectory(folder)
        let temporary = folder.appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: file, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if overwrite {
            // rename(2) replaces the destination atomically: there is never a moment without a file.
            guard Foundation.rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            return true
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            return true
        } catch {
            // Another writer stored the same content first: fine.
            if Self.fileSize(destination) != nil { return false }
            throw error
        }
    }

    /// Reads, authenticates and (for raw messages) decompresses a stored file.
    public func read(_ hash: Data) throws -> Data {
        let source = url(for: hash)
        guard let file = FileManager.default.contents(atPath: source.path) else { throw EncryptedFileError.missing }
        return try open(file, hash: hash)
    }

    func open(_ file: Data, hash: Data) throws -> Data {
        guard file.count > 6, Array(file.prefix(4)) == Self.magic else { throw EncryptedFileError.notAStowFile }
        let version = file[file.startIndex + 4]
        guard version == Self.version else { throw EncryptedFileError.unsupportedVersion(version) }
        let flags = file[file.startIndex + 5]
        let header = file.prefix(6)
        let payload: Data
        do {
            let box = try AES.GCM.SealedBox(combined: file.dropFirst(6))
            payload = try AES.GCM.open(box, using: encryptionKey, authenticating: Data(header) + hash)
        } catch {
            throw EncryptedFileError.authenticationFailed
        }
        guard flags & Self.flagCompressed != 0 else { return payload }
        do {
            return try (payload as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw EncryptedFileError.decompressionFailed
        }
    }

    /// Replaces a stored file's content in place (used only by raw message
    /// compaction, which keeps the file name of the original).
    func replace(_ hash: Data, with content: Data) throws -> Int {
        let file = try seal(content, hash: hash)
        _ = try place(file, at: url(for: hash), overwrite: true)
        return file.count
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }
}
