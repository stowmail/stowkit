import CryptoKit
import Foundation

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
        let digest = Array(SHA256.hash(data: Data("uk.getstow.recovery.check".utf8) + bytes))
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
    static let version = 1
    static let info = Data("uk.getstow.recovery.v1".utf8)

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
    }

    /// Wraps `keys` with `recoveryKey` and writes the bundle into `archiveFolder`
    /// (permissions 0600), replacing any earlier bundle atomically.
    public static func write(_ keys: ArchiveKeys, archiveID: String, recoveryKey: RecoveryKey, to archiveFolder: URL) throws {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let contents = try JSONEncoder().encode(Contents(
            databaseKey: keys.databaseKeyData, fileKey: keys.fileKey.withUnsafeBytes { Data($0) }))
        let sealed = try AES.GCM.seal(contents, using: wrappingKey(recoveryKey, salt: salt), authenticating: authenticated(archiveID))
        guard let combined = sealed.combined else { throw RecoveryBundleError.unreadable }
        let file = File(format: "uk.getstow.recovery", version: version, archiveID: archiveID, createdAt: Date(), salt: salt, sealed: combined)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = archiveFolder.appendingPathComponent(fileName)
        let temporary = archiveFolder.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(file),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw RecoveryBundleError.unreadable
        }
        guard Foundation.rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw RecoveryBundleError.unreadable
        }
    }

    /// The archive ID the bundle in `archiveFolder` belongs to, without unwrapping anything.
    public static func archiveID(in archiveFolder: URL) throws -> String {
        try read(archiveFolder).archiveID
    }

    public static func exists(in archiveFolder: URL) -> Bool {
        FileManager.default.fileExists(atPath: archiveFolder.appendingPathComponent(fileName).path)
    }

    /// Unwraps the keys in `archiveFolder`'s bundle. Returns them with the archive ID they belong to.
    public static func unwrap(in archiveFolder: URL, with recoveryKey: RecoveryKey) throws -> (keys: ArchiveKeys, archiveID: String) {
        let file = try read(archiveFolder)
        let contents: Contents
        do {
            let box = try AES.GCM.SealedBox(combined: file.sealed)
            let plain = try AES.GCM.open(box, using: wrappingKey(recoveryKey, salt: file.salt), authenticating: authenticated(file.archiveID))
            contents = try JSONDecoder().decode(Contents.self, from: plain)
        } catch {
            throw RecoveryBundleError.wrongKey
        }
        guard contents.databaseKey.count == 32, contents.fileKey.count == 32 else { throw RecoveryBundleError.unreadable }
        return (ArchiveKeys(databaseKey: SymmetricKey(data: contents.databaseKey), fileKey: SymmetricKey(data: contents.fileKey)),
                file.archiveID)
    }

    static func read(_ archiveFolder: URL) throws -> File {
        guard let data = FileManager.default.contents(atPath: archiveFolder.appendingPathComponent(fileName).path) else {
            throw RecoveryBundleError.missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.format == "uk.getstow.recovery" else {
            throw RecoveryBundleError.unreadable
        }
        guard file.version == version else { throw RecoveryBundleError.unsupportedVersion(file.version) }
        return file
    }

    static func wrappingKey(_ recoveryKey: RecoveryKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recoveryKey.bytes), salt: salt, info: info, outputByteCount: 32)
    }

    static func authenticated(_ archiveID: String) -> Data {
        Data("uk.getstow.recovery.v1|\(archiveID)".utf8)
    }
}
