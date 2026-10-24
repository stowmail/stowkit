import CryptoKit
import Foundation

/// The archive's encryption keys, loaded from the Keychain.
///
/// Two random 256-bit keys are stored (D-016):
/// - the database key, given to SQLCipher as a raw key;
/// - the file key, from which two subkeys are derived with HKDF: one for
///   AES-GCM encryption of attachment and raw message files, one for the
///   HMAC-SHA256 that names attachment files (D-003).
///
/// Deriving the file subkeys keeps the recovery bundle to two secrets while
/// never using one key for two jobs.
public struct ArchiveKeys: Sendable {
    public let databaseKey: SymmetricKey
    public let fileKey: SymmetricKey

    public init(databaseKey: SymmetricKey, fileKey: SymmetricKey) {
        self.databaseKey = databaseKey
        self.fileKey = fileKey
    }

    /// The database key as raw bytes, for SQLCipher's `PRAGMA key = "x'…'"`.
    public var databaseKeyData: Data {
        databaseKey.withUnsafeBytes { Data($0) }
    }

    /// AES-GCM key for attachment and raw message files.
    public var fileEncryptionKey: SymmetricKey {
        derive(info: "ee.getstow.file-encryption.v1")
    }

    /// HMAC-SHA256 key for naming attachment files by content.
    public var fileNamingKey: SymmetricKey {
        derive(info: "ee.getstow.file-naming.v1")
    }

    private func derive(info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: fileKey,
            salt: Data("ee.getstow.stow".utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }
}

public enum KeyManagerError: Error, Equatable, CustomStringConvertible {
    /// `createKeys()` was called but keys already exist. Replacing them would
    /// make the existing archive unreadable, so this is refused.
    case keysAlreadyExist
    /// No keys in the Keychain. Run setup (or restore from the recovery key).
    case keysMissing
    /// Only one of the two keys is present: the Keychain was changed outside Stow.
    case keysIncomplete
    case malformedKey(String)

    public var description: String {
        switch self {
        case .keysAlreadyExist: "Archive keys already exist; refusing to replace them"
        case .keysMissing: "No archive keys in the Keychain. Run setup, or restore with the recovery key"
        case .keysIncomplete: "Only one archive key is in the Keychain; the archive cannot be opened"
        case .malformedKey(let item): "Keychain item \(item) is not a 256-bit key"
        }
    }
}

/// Creates and loads the archive keys.
///
/// Creating and loading are deliberately separate: `loadKeys()` never makes
/// new keys, so a Keychain hiccup can never silently replace the key an
/// existing archive was encrypted with.
public struct KeyManager: Sendable {
    static let databaseKeyItem = "key.database.v1"
    static let fileKeyItem = "key.files.v1"

    public let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    public func keysExist() throws -> Bool {
        let database = try keychain.get(Self.databaseKeyItem) != nil
        let files = try keychain.get(Self.fileKeyItem) != nil
        if database != files { throw KeyManagerError.keysIncomplete }
        return database
    }

    /// Generates both keys and saves them. Fails if any key already exists.
    @discardableResult
    public func createKeys() throws -> ArchiveKeys {
        guard try keychain.get(Self.databaseKeyItem) == nil,
              try keychain.get(Self.fileKeyItem) == nil
        else { throw KeyManagerError.keysAlreadyExist }

        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        try keychain.set(keys.databaseKeyData, for: Self.databaseKeyItem)
        do {
            try keychain.set(keys.fileKey.withUnsafeBytes { Data($0) }, for: Self.fileKeyItem)
        } catch {
            try? keychain.delete(Self.databaseKeyItem)
            throw error
        }
        return keys
    }

    /// Saves keys recovered from the recovery bundle (D-031). Refuses if any
    /// Stow key is already in the Keychain: recovery never overwrites keys.
    public func installRecovered(_ keys: ArchiveKeys) throws {
        guard try keychain.get(Self.databaseKeyItem) == nil,
              try keychain.get(Self.fileKeyItem) == nil
        else { throw KeyManagerError.keysAlreadyExist }
        try keychain.set(keys.databaseKeyData, for: Self.databaseKeyItem)
        do {
            try keychain.set(keys.fileKey.withUnsafeBytes { Data($0) }, for: Self.fileKeyItem)
        } catch {
            try? keychain.delete(Self.databaseKeyItem)
            throw error
        }
    }

    /// Loads both keys. Never creates them.
    public func loadKeys() throws -> ArchiveKeys {
        let database = try keychain.get(Self.databaseKeyItem)
        let files = try keychain.get(Self.fileKeyItem)
        switch (database, files) {
        case (nil, nil):
            throw KeyManagerError.keysMissing
        case (let database?, let files?):
            return ArchiveKeys(
                databaseKey: try Self.key(from: database, item: Self.databaseKeyItem),
                fileKey: try Self.key(from: files, item: Self.fileKeyItem)
            )
        default:
            throw KeyManagerError.keysIncomplete
        }
    }

    private static func key(from data: Data, item: String) throws -> SymmetricKey {
        guard data.count == 32 else { throw KeyManagerError.malformedKey(item) }
        return SymmetricKey(data: data)
    }
}
