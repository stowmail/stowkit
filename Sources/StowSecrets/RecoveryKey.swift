import CryptoKit
import Foundation
import StowCore

public enum RecoveryKeyError: Error, Equatable, CustomStringConvertible {
    case wrongLength(Int)
    case invalidCharacter(Character)
    /// The check characters do not match: almost certainly a typing mistake.
    case checkFailed

    public var description: String {
        switch self {
        case .wrongLength(let count):
            "A recovery key has \(RecoveryKey.characterCount) characters (not counting dashes); this has \(count)."
        case .invalidCharacter(let character):
            "\"\(character)\" cannot appear in a recovery key. Check for a mistyped character."
        case .checkFailed:
            "That recovery key has a typing mistake somewhere: its check characters do not match."
        }
    }
}

/// The recovery key (D-007, D-031): 256 random bits the user keeps, for example
/// in a password manager. With it and a copy of the archive folder, the
/// archive can be opened on a new Mac, because it unlocks the key bundle
/// (`RecoveryBundle`) stored beside the archive.
///
/// Written as 56 Crockford base32 characters in 14 groups of four, for example
/// `7K3M-2M9X-...`: 52 carry the key and the last four are a check, so a typing
/// mistake is caught before anything is tried. Crockford's alphabet has no
/// I, L, O or U, and reading accepts I and L as 1 and O as 0, in any case.
///
/// Stow never stores it: it is shown once, and replacing it means making a new one.
public struct RecoveryKey: Sendable, Equatable {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let keyCharacters = 52
    static let checkCharacters = 4
    public static let characterCount = keyCharacters + checkCharacters
    public static let groupCount = characterCount / 4

    /// The 32 secret bytes.
    let bytes: Data

    init(bytes: Data) {
        precondition(bytes.count == 32)
        self.bytes = bytes
    }

    /// A new random key.
    public static func generate() -> RecoveryKey {
        RecoveryKey(bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Reads a key as the user typed it. Dashes, spaces and case do not matter.
    public init(_ text: String) throws {
        var characters: [Character] = []
        for character in text.uppercased() where character != "-" && !character.isWhitespace {
            switch character {
            case "I", "L": characters.append("1")
            case "O": characters.append("0")
            default:
                guard Self.alphabet.contains(character) else { throw RecoveryKeyError.invalidCharacter(character) }
                characters.append(character)
            }
        }
        guard characters.count == Self.characterCount else { throw RecoveryKeyError.wrongLength(characters.count) }
        let bytes = try Self.decode(Array(characters.prefix(Self.keyCharacters)))
        let key = RecoveryKey(bytes: bytes)
        guard key.check == String(characters.suffix(Self.checkCharacters)) else { throw RecoveryKeyError.checkFailed }
        self = key
    }

    /// The key as shown to the user: 14 groups of four characters, joined by dashes.
    public var displayString: String { groups.joined(separator: "-") }

    public var groups: [String] {
        let all = Array(Self.encode(bytes) + check)
        return stride(from: 0, to: all.count, by: 4).map { String(all[$0..<$0 + 4]) }
    }

    /// Whether `typed` is group number `index` (0-based), however it was typed.
    public func groupMatches(_ index: Int, typed: String) -> Bool {
        let normalised = String(typed.uppercased().filter { $0 != "-" && !$0.isWhitespace }.map { c -> Character in
            switch c {
            case "I", "L": "1"
            case "O": "0"
            default: c
            }
        })
        return groups.indices.contains(index) && groups[index] == normalised
    }

    /// Four check characters from a hash of the key.
    var check: String {
        let digest = Array(SHA256.hash(data: Data("ee.getstow.recovery.check".utf8) + bytes))
        let value = Int(digest[0]) << 12 | Int(digest[1]) << 4 | Int(digest[2]) >> 4
        return String((0..<4).map { Self.alphabet[(value >> (15 - $0 * 5)) & 31] })
    }

    /// 256 bits as 52 characters, five bits each, the last four bits zero.
    static func encode(_ bytes: Data) -> String {
        var output: [Character] = []
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return String(output)
    }

    static func decode(_ characters: [Character]) throws -> Data {
        var bytes = Data()
        var buffer = 0
        var bits = 0
        for character in characters {
            guard let value = alphabet.firstIndex(of: character) else { throw RecoveryKeyError.invalidCharacter(character) }
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
            }
            buffer &= (1 << bits) - 1
        }
        // The four leftover bits are padding and must be zero in a key Stow made.
        guard bytes.count == 32, buffer == 0 else { throw RecoveryKeyError.checkFailed }
        return bytes
    }
}

public enum RecoveryBundleError: Error, Equatable, CustomStringConvertible {
    case missing
    case unreadable
    case unsupportedVersion(Int)
    /// The key does not open this bundle: a different archive's key, or a typing mistake the check did not catch.
    case wrongKey

    public var description: String {
        switch self {
        case .missing: "There is no recovery bundle (\(RecoveryBundle.fileName)) in that folder. Is it the archive folder?"
        case .unreadable: "The recovery bundle is damaged."
        case .unsupportedVersion(let version): "The recovery bundle is version \(version), which this build cannot read."
        case .wrongKey: "That recovery key does not open this archive."
        }
    }
}

/// The archive's two keys, wrapped with the recovery key and kept beside the
/// archive as `keys.recovery`, so any backup of the archive folder carries
/// them (D-007, D-031).
///
/// The wrapping key comes from the recovery key with HKDF-SHA256 and a random
/// salt; the keys are sealed with AES-256-GCM. The archive's ID is
/// authenticated data, so a bundle cannot be swapped onto another archive.
/// No slow password hashing is needed: the recovery key is random, not a password.
public struct RecoveryBundle: Sendable {
    public static let fileName = "keys.recovery"
    /// A new bundle waiting for its key to be confirmed (D-480). Same format;
    /// `recover` never reads it.
    public static let pendingFileName = "keys.recovery.pending"
    static let version = 1
    static let info = Data("ee.getstow.recovery.v1".utf8)

    struct File: Codable {
        var format: String
        var version: Int
        var archiveID: String
        var createdAt: Date
        var salt: Data
        var sealed: Data
    }

    struct Contents: Codable {
        var databaseKey: Data
        var fileKey: Data

        mutating func wipe() {
            databaseKey.resetBytes(in: 0..<databaseKey.count)
            fileKey.resetBytes(in: 0..<fileKey.count)
        }
    }

    /// Wraps `keys` with `recoveryKey` and writes the bundle into `archiveFolder`
    /// as `name` (permissions 0600), replacing any earlier file of that name
    /// atomically. The file is flushed to the drive before the rename and the
    /// folder after it (A-04), so a power cut leaves the old file or the new
    /// one, whole. A new key is written as `pendingFileName` (D-480).
    public static func write(_ keys: ArchiveKeys, archiveID: String, recoveryKey: RecoveryKey, to archiveFolder: URL,
                             name: String = fileName, sync: DiskSync = .system) throws {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // The keys pass through JSON (the file format); the plaintext and the key
        // copies made for it are wiped once sealed (D-519). JSONEncoder's own
        // base64 text in between cannot be reached.
        var plain = Contents(databaseKey: keys.databaseKeyData, fileKey: keys.fileKey.withUnsafeBytes { Data($0) })
        var contents = try JSONEncoder().encode(plain)
        defer {
            plain.wipe()
            contents.resetBytes(in: 0..<contents.count)
        }
        let sealed = try AES.GCM.seal(contents, using: wrappingKey(recoveryKey, salt: salt), authenticating: authenticated(archiveID))
        guard let combined = sealed.combined else { throw RecoveryBundleError.unreadable }
        let file = File(format: "ee.getstow.recovery", version: version, archiveID: archiveID, createdAt: Date(), salt: salt, sealed: combined)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(file)
        let url = archiveFolder.appendingPathComponent(name)
        let temporary = archiveFolder.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RecoveryBundleError.unreadable }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: bytes)
            try sync.flushFile(descriptor, path: temporary.path)
            try handle.close()
            try sync.rename(temporary, to: url)
        } catch {
            unlink(temporary.path)
            throw error
        }
        try sync.flushFolder(archiveFolder)
    }

    /// Makes the confirmed pending bundle the live one: one rename, then the
    /// folder flushed. `keys.recovery` is the old bundle or the new one at every moment.
    public static func promotePending(in archiveFolder: URL, sync: DiskSync = .system) throws {
        try sync.rename(archiveFolder.appendingPathComponent(pendingFileName), to: archiveFolder.appendingPathComponent(fileName))
        try sync.flushFolder(archiveFolder)
    }

    /// Deletes a pending bundle nobody confirmed. The live bundle is not touched.
    public static func removePending(in archiveFolder: URL, sync: DiskSync = .system) throws {
        let url = archiveFolder.appendingPathComponent(pendingFileName)
        try sync.note(.unlink(url.path))
        guard unlink(url.path) == 0 || errno == ENOENT else { throw RecoveryBundleError.unreadable }
        try sync.flushFolder(archiveFolder)
    }

    /// The archive ID the bundle in `archiveFolder` belongs to, without unwrapping anything.
    public static func archiveID(in archiveFolder: URL) throws -> String {
        try read(archiveFolder).archiveID
    }

    public static func exists(in archiveFolder: URL, name: String = fileName) -> Bool {
        FileManager.default.fileExists(atPath: archiveFolder.appendingPathComponent(name).path)
    }

    /// SHA-256 of the bundle file, in hex, so a confirmation can name the
    /// exact bundle it confirmed (D-086). Any new bundle has a new random salt,
    /// so it never shares a fingerprint with an older one.
    public static func fingerprint(in archiveFolder: URL, name: String = fileName) throws -> String {
        guard let data = FileManager.default.contents(atPath: archiveFolder.appendingPathComponent(name).path) else {
            throw RecoveryBundleError.missing
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Unwraps the keys in `archiveFolder`'s bundle. Returns them with the archive ID they belong to.
    public static func unwrap(in archiveFolder: URL, name: String = fileName, with recoveryKey: RecoveryKey) throws -> (keys: ArchiveKeys, archiveID: String) {
        let file = try read(archiveFolder, name: name)
        var contents: Contents
        do {
            let box = try AES.GCM.SealedBox(combined: file.sealed)
            var plain = try AES.GCM.open(box, using: wrappingKey(recoveryKey, salt: file.salt), authenticating: authenticated(file.archiveID))
            defer { plain.resetBytes(in: 0..<plain.count) }
            contents = try JSONDecoder().decode(Contents.self, from: plain)
        } catch {
            throw RecoveryBundleError.wrongKey
        }
        // The decoded copies are wiped once the keys are in CryptoKit's storage (D-519).
        defer { contents.wipe() }
        guard contents.databaseKey.count == 32, contents.fileKey.count == 32 else { throw RecoveryBundleError.unreadable }
        return (ArchiveKeys(databaseKey: SymmetricKey(data: contents.databaseKey), fileKey: SymmetricKey(data: contents.fileKey)),
                file.archiveID)
    }

    static func read(_ archiveFolder: URL, name: String = fileName) throws -> File {
        guard let data = FileManager.default.contents(atPath: archiveFolder.appendingPathComponent(name).path) else {
            throw RecoveryBundleError.missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.format == "ee.getstow.recovery" else {
            throw RecoveryBundleError.unreadable
        }
        guard file.version == version else { throw RecoveryBundleError.unsupportedVersion(file.version) }
        return file
    }

    static func wrappingKey(_ recoveryKey: RecoveryKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recoveryKey.bytes), salt: salt, info: info, outputByteCount: 32)
    }

    static func authenticated(_ archiveID: String) -> Data {
        Data("ee.getstow.recovery.v1|\(archiveID)".utf8)
    }
}
