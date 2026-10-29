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

    /// A SHA-256 over both keys, to tell whether two sets of keys are the same
    /// without keeping a second copy of either (A-09, D-486). It reveals nothing
    /// about the keys: they are 256 random bits each.
    public var digest: KeysDigest {
        var hash = SHA256()
        hash.update(data: Data("ee.getstow.archive-keys.digest.v1".utf8))
        databaseKey.withUnsafeBytes { hash.update(bufferPointer: $0) }
        fileKey.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return KeysDigest(bytes: Data(hash.finalize()))
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

/// A digest of an archive's two keys (`ArchiveKeys.digest`). Compared in constant time.
public struct KeysDigest: Sendable {
    let bytes: Data

    public func matches(_ other: KeysDigest) -> Bool {
        guard bytes.count == other.bytes.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(bytes, other.bytes) { difference |= a ^ b }
        return difference == 0
    }
}

public enum KeyManagerError: Error, Equatable, CustomStringConvertible {
    /// `createKeys()` was called but keys already exist. Replacing them would
    /// make the existing archive unreadable, so this is refused.
    case keysAlreadyExist
    /// Neither key is in the Keychain searched: this backend and service.
    case keysMissing(backend: KeychainBackend, service: String)
    /// Only one of the two keys is present: the Keychain was changed outside Stow.
    case keysIncomplete
    case malformedKey(String)

    public var description: String {
        switch self {
        case .keysAlreadyExist: "Archive keys already exist; refusing to replace them"
        case .keysMissing(let backend, let service):
            Self.keysMissingDescription(backend: backend, service: service)
        case .keysIncomplete: "Only one archive key is in the Keychain; the archive cannot be opened"
        case .malformedKey(let item): "Keychain item \(item) is not a 256-bit key"
        }
    }

    /// Says where Stow looked, because the usual cause is looking in the wrong
    /// place, and never suggests `init`, which is wrong for an existing archive (D-082).
    /// The STOW_KEYCHAIN hint holds until builds are signed (D-012).
    static func keysMissingDescription(backend: KeychainBackend, service: String) -> String {
        let place = switch backend {
        case .file: "the login keychain (STOW_KEYCHAIN=file)"
        case .dataProtection: "the data protection keychain"
        }
        var text = "The archive keys are not in \(place) under \"\(service)\", so the archive cannot be opened."
        if backend == .dataProtection {
            text += " Development builds keep their keys in the login keychain: set STOW_KEYCHAIN=file and try again (for the background sync, run `stowmail daemon install` with it set)."
        } else if service != KeychainStore.defaultService {
            text += " STOW_KEYCHAIN_SERVICE is set; unset it if this is the real archive."
        }
        text += " If the keys are really gone, restore them with `stowmail recover --archive <folder>` and the recovery key."
        return text
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
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        try addBoth(keys)
        return keys
    }

    /// Saves keys recovered from the recovery bundle (D-031). Refuses if any
    /// Stow key is already in the Keychain: recovery never overwrites keys.
    public func installRecovered(_ keys: ArchiveKeys) throws {
        try addBoth(keys)
    }

    /// Adds both items, never replacing one (A-09). Two callers at once (two
    /// `init` runs, or the app and the CLI) can both pass a "nothing there yet"
    /// check, so the add itself is the check: whoever adds the database key
    /// first goes on, the other is refused. If the file key cannot be added,
    /// the database key this call added is taken out again; nothing else is.
    private func addBoth(_ keys: ArchiveKeys) throws {
        guard try keychain.get(Self.databaseKeyItem) == nil,
              try keychain.get(Self.fileKeyItem) == nil
        else { throw KeyManagerError.keysAlreadyExist }
        // The Keychain takes a CFData; each copy made for it is wiped once added (D-519).
        var databaseData = keys.databaseKeyData
        var fileData = keys.fileKey.withUnsafeBytes { Data($0) }
        defer {
            databaseData.resetBytes(in: 0..<databaseData.count)
            fileData.resetBytes(in: 0..<fileData.count)
        }
        do {
            try keychain.add(databaseData, for: Self.databaseKeyItem)
        } catch KeychainError.alreadyExists {
            throw KeyManagerError.keysAlreadyExist
        }
        do {
            try keychain.add(fileData, for: Self.fileKeyItem)
        } catch {
            try? keychain.delete(Self.databaseKeyItem)
            if case KeychainError.alreadyExists = error { throw KeyManagerError.keysAlreadyExist }
            throw error
        }
    }

    /// Loads both keys. Never creates them.
    public func loadKeys() throws -> ArchiveKeys {
        var database = try keychain.get(Self.databaseKeyItem)
        var files = try keychain.get(Self.fileKeyItem)
        // The Keychain's copies are wiped once the keys are in CryptoKit's own storage (D-519).
        defer {
            let databaseCount = database?.count ?? 0, filesCount = files?.count ?? 0
            database?.resetBytes(in: 0..<databaseCount)
            files?.resetBytes(in: 0..<filesCount)
        }
        switch (database, files) {
        case (nil, nil):
            throw KeyManagerError.keysMissing(backend: keychain.backend, service: keychain.service)
        case (let database?, let files?):
            return ArchiveKeys(
                databaseKey: try Self.key(from: database, item: Self.databaseKeyItem),
                fileKey: try Self.key(from: files, item: Self.fileKeyItem)
            )
        default:
            throw KeyManagerError.keysIncomplete
        }
    }

    /// Loads only the database key, for readers that never open the encrypted
    /// files (the MCP server, D-081): one Keychain item, so one prompt at most.
    /// Never creates it. The Keychain's copy is wiped once it is in the buffer (D-519).
    public func loadDatabaseKey() throws -> KeyBuffer {
        guard var data = try keychain.get(Self.databaseKeyItem) else {
            throw KeyManagerError.keysMissing(backend: keychain.backend, service: keychain.service)
        }
        defer { data.resetBytes(in: 0..<data.count) }
        guard data.count == 32 else { throw KeyManagerError.malformedKey(Self.databaseKeyItem) }
        return KeyBuffer(data)
    }

    private static func key(from data: Data, item: String) throws -> SymmetricKey {
        guard data.count == 32 else { throw KeyManagerError.malformedKey(item) }
        return SymmetricKey(data: data)
    }
}
