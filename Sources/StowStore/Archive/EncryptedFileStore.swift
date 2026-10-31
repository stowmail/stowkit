import CryptoKit
import Foundation
import Logging
import StowCore
import StowSecrets

public enum EncryptedFileError: Error, Equatable, CustomStringConvertible {
    case notAStowFile
    case unsupportedVersion(UInt8)
    /// A flag bit this build does not know, such as a newer compression (D-536).
    case unsupportedFeature(UInt8)
    /// Wrong key, a damaged file, or a file moved to a different name.
    case authenticationFailed
    case decompressionFailed
    case missing

    public var description: String {
        switch self {
        case .notAStowFile: "Not a Stow archive file"
        case .unsupportedVersion(let version): "Unsupported archive file version \(version)"
        case .unsupportedFeature: "Archive file uses a feature this version of Stow does not know. Update Stow to open it."
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
///   compressed; bit 1: a message skeleton, D-029), then AES-256-GCM
///   `nonce | ciphertext | tag`. The header and the file's own hash are
///   authenticated data, so a file renamed or swapped with another, or with
///   its flags altered, fails to open rather than returning the wrong content.
/// - **Writes** happen once: a file that already exists and checks out is left
///   alone, which is what makes attachments deduplicate. Written to a temporary
///   name with permissions 0600, flushed to the drive, renamed into place, and
///   the folder flushed, so the file is whole on disk before any row that uses
///   it is written (A-05). Files are deleted only when the user removes mail
///   from the archive and nothing else uses them (D-033).
/// - **Reuse is checked** (A-05): an existing file must open with this key and
///   address (an attachment must also have exactly its sealed size). One that
///   does not, such as a file torn by a power cut before flushing was added, is
///   replaced in one rename by a fresh copy of the same content.
public struct EncryptedFileStore: Sendable {
    public enum Kind: Sendable {
        case raw
        case attachment
    }

    static let magic: [UInt8] = Array("STOW".utf8)
    static let version: UInt8 = 1
    static let flagCompressed: UInt8 = 1
    static let flagSkeleton: UInt8 = 2
    /// Every flag this build reads. Any other bit means a newer format, which
    /// must be refused rather than read as if the bit were not there (D-536).
    static let knownFlags: UInt8 = flagCompressed | flagSkeleton
    /// Header (magic, version, flags), nonce and tag around the sealed payload.
    static let overhead = 6 + 12 + 16

    public let directory: URL
    public let kind: Kind
    let encryptionKey: SymmetricKey
    let namingKey: SymmetricKey
    let diskSync: DiskSync
    static let logger = Logger(label: "ee.getstow.store.files")

    public init(directory: URL, kind: Kind, keys: ArchiveKeys, diskSync: DiskSync = .system) {
        self.directory = directory
        self.kind = kind
        encryptionKey = keys.fileEncryptionKey
        namingKey = keys.fileNamingKey
        self.diskSync = diskSync
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

    /// Stores `content` under `hash` unless an intact file is already there.
    /// `skeleton` marks a raw message file whose attachments were cut out (D-029).
    /// Returns the size on disk, and whether this call wrote it (including
    /// replacing a damaged file).
    ///
    /// With `replacingDamaged` false a damaged file is reported, not replaced:
    /// for a raw file whose existing rows expect a form this write cannot give.
    @discardableResult
    public func write(_ content: Data, hash: Data, skeleton: Bool = false,
                      replacingDamaged: Bool = true) throws -> (storedSize: Int, written: Bool) {
        let destination = url(for: hash)
        var damaged = false
        if let size = Self.fileSize(destination) {
            if isIntact(destination, size: size, content: content, hash: hash) { return (size, false) }
            guard replacingDamaged else {
                Self.logger.error("A damaged stored file could not be replaced in the form its messages need", metadata: [
                    "file": "\(hash.hex.prefix(12))", "size": "\(size)",
                ])
                throw EncryptedFileError.authenticationFailed
            }
            damaged = true
            // Hash prefix and sizes only: never content (CLAUDE.md).
            Self.logger.warning("Replacing a damaged stored file", metadata: [
                "file": "\(hash.hex.prefix(12))", "size": "\(size)", "contentSize": "\(content.count)",
            ])
        }
        let file = try seal(content, hash: hash, skeleton: skeleton)
        let written = try place(file, at: destination, replacing: damaged)
        return (written ? file.count : Self.fileSize(destination) ?? file.count, written)
    }

    /// Whether the file at `url` opens with this key and address. An attachment
    /// is sealed without compression, so its size must also be exactly the
    /// sealed size, checked first so most damage costs no read.
    func isIntact(_ url: URL, size: Int, content: Data, hash: Data) -> Bool {
        if kind == .attachment, size != content.count + Self.overhead { return false }
        guard let file = FileManager.default.contents(atPath: url.path), let opened = try? open(file, hash: hash) else { return false }
        // A raw file may hold the skeleton or the whole message; the importer checks it rebuilds.
        return kind == .raw || opened == content
    }

    func seal(_ content: Data, hash: Data, skeleton: Bool = false) throws -> Data {
        var flags: UInt8 = 0
        var payload = content
        if kind == .raw {
            payload = try (content as NSData).compressed(using: .lzfse) as Data
            flags |= Self.flagCompressed
        }
        if skeleton { flags |= Self.flagSkeleton }
        let header = Self.magic + [Self.version, flags]
        let sealed = try AES.GCM.seal(payload, using: encryptionKey, authenticating: Data(header) + hash)
        guard let combined = sealed.combined else { throw EncryptedFileError.authenticationFailed }
        return Data(header) + combined
    }

    /// Writes to a temporary file (0600) in the same folder, hands it to the
    /// drive (`fsync`), renames it into place and hands over the folder too
    /// (and the store's folder when the two-character folder is new). The
    /// caller puts one barrier (`DiskSync.barrier`) after its files and before
    /// the rows that use them, which keeps the order at a fraction of the cost
    /// of a full flush per file (L-5, D-507). Without
    /// `replacing`, an existing file wins and this returns false; with it, a
    /// damaged file is replaced in one step.
    private func place(_ file: Data, at destination: URL, replacing: Bool) throws -> Bool {
        let folder = destination.deletingLastPathComponent()
        let newFolder = !FileManager.default.fileExists(atPath: folder.path)
        try ArchiveLocation.makeDirectory(folder)
        if newFolder { try diskSync.flushFolder(directory, .handedOver) }
        let temporary = folder.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let descriptor = Foundation.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: file)
            try diskSync.flushFile(descriptor, path: temporary.path, .handedOver)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if replacing {
            try diskSync.rename(temporary, to: destination)
        } else {
            try diskSync.note(.rename(from: temporary.path, to: destination.path))
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                // Another writer stored the same content first: fine.
                if errno == EEXIST { return false }
                throw DiskSyncError.renameFailed(errno)
            }
        }
        try diskSync.flushFolder(folder, .handedOver)
        return true
    }

    /// Reads, authenticates and (for raw messages) decompresses a stored file.
    public func read(_ hash: Data) throws -> Data {
        try readFile(hash).content
    }

    /// Like `read`, plus whether the file is marked as a message skeleton.
    public func readFile(_ hash: Data) throws -> (content: Data, isSkeleton: Bool) {
        let source = url(for: hash)
        guard let file = FileManager.default.contents(atPath: source.path) else { throw EncryptedFileError.missing }
        let content = try open(file, hash: hash)
        return (content, file[file.startIndex + 5] & Self.flagSkeleton != 0)
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
        // After authentication, so a damaged or forged header says so (D-536).
        guard flags & ~Self.knownFlags == 0 else { throw EncryptedFileError.unsupportedFeature(flags) }
        guard flags & Self.flagCompressed != 0 else { return payload }
        do {
            return try (payload as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw EncryptedFileError.decompressionFailed
        }
    }

    /// Deletes a stored file. Missing files are not an error. Only the tidy-up
    /// calls this, after the database no longer refers to the file (D-033).
    public func delete(_ hash: Data) throws {
        do {
            try FileManager.default.removeItem(at: url(for: hash))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// The hash of every file in the store, for finding files the database no longer uses.
    public func allHashes() -> [Data] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var hashes: [Data] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.count == 64, let hash = Data(hex: name) else { continue }
            hashes.append(hash)
        }
        return hashes
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }
}

extension Data {
    /// Bytes from a hex string, or nil if it is not valid hex.
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// Lowercase hex.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
