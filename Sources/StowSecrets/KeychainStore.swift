import Foundation
import Security

/// Which macOS keychain items are stored in (D-012).
public enum KeychainBackend: String, Sendable, CaseIterable {
    /// The modern "data protection" keychain. Items are `AfterFirstUnlockThisDeviceOnly`
    /// and never synchronised, as D-007 requires. Needs a binary signed with a
    /// keychain entitlement; unsigned builds get `errSecMissingEntitlement`.
    case dataProtection
    /// The older file-based login keychain. Works for unsigned command-line builds,
    /// but macOS ignores the `ThisDeviceOnly` setting there. Used until builds are
    /// signed, only when chosen explicitly with `STOW_KEYCHAIN=file`, and only while
    /// FileVault is on (D-012).
    case file

    /// The environment variable that selects the backend.
    public static let environmentKey = "STOW_KEYCHAIN"

    /// `.dataProtection` unless `STOW_KEYCHAIN=file` is set. Never falls back silently.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> KeychainBackend {
        environment[environmentKey]?.lowercased() == "file" ? .file : .dataProtection
    }
}

public enum KeychainError: Error, Equatable, CustomStringConvertible {
    /// The binary is not signed with a keychain entitlement, so the data
    /// protection keychain refused it.
    case missingEntitlement
    /// The login keychain backend was chosen but FileVault is off (D-012).
    case fileVaultRequired
    case unexpectedStatus(OSStatus)
    case unexpectedData
    /// `add` found an item of that name already there; it was left unchanged.
    case alreadyExists

    public var description: String {
        switch self {
        case .missingEntitlement:
            "This build is not signed with a keychain entitlement, so the data protection keychain is unavailable (D-012). For development, set STOW_KEYCHAIN=file to use the login keychain."
        case .fileVaultRequired:
            "STOW_KEYCHAIN=file is only allowed while FileVault is on (D-012). Turn on FileVault in System Settings > Privacy & Security."
        case .unexpectedStatus(let status):
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        case .unexpectedData:
            "Keychain returned data in an unexpected form"
        case .alreadyExists:
            "The Keychain already holds that item; it was left unchanged"
        }
    }

    init(status: OSStatus) {
        self = status == errSecMissingEntitlement ? .missingEntitlement : .unexpectedStatus(status)
    }
}

/// Whether FileVault full-disk encryption is on.
public enum FileVault {
    /// Asks `fdesetup isactive`, once per process. Any failure counts as off.
    public static let isOn: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["isactive"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 && text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }()
}

/// Stores small secrets as generic password items in the macOS Keychain.
///
/// Every item is filed under one service name (`ee.getstow.stow` by default)
/// and an item name such as `oauth.<account id>`. Items are created
/// `AfterFirstUnlockThisDeviceOnly` and not synchronisable (D-007).
public struct KeychainStore: Sendable {
    public static let defaultService = "ee.getstow.stow"

    public let service: String
    public let backend: KeychainBackend
    /// Reports whether FileVault is on. Only consulted for the `.file` backend.
    let fileVaultIsOn: @Sendable () -> Bool

    /// - Parameter fileVaultIsOn: tests that store only fake values pass `{ true }`;
    ///   everything else keeps the default, the real FileVault check.
    public init(
        service: String = KeychainStore.defaultService,
        backend: KeychainBackend = .fromEnvironment(),
        fileVaultIsOn: @escaping @Sendable () -> Bool = { FileVault.isOn }
    ) {
        self.service = service
        self.backend = backend
        self.fileVaultIsOn = fileVaultIsOn
    }

    /// The login keychain is only used while FileVault is on (D-012). Deleting is
    /// always allowed, so secrets can be removed whatever the disk state.
    private func checkBackendAllowed() throws {
        if backend == .file && !fileVaultIsOn() {
            throw KeychainError.fileVaultRequired
        }
    }

    /// Saves `data` under `item` only if no item of that name exists. The
    /// check and the write are one Keychain call, so two processes adding at
    /// once cannot both succeed (A-09). An existing item is never touched.
    public func add(_ data: Data, for item: String) throws {
        try checkBackendAllowed()
        let status = SecItemAdd(addAttributes(item: item, data: data) as CFDictionary, nil)
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw KeychainError.alreadyExists
        default: throw KeychainError(status: status)
        }
    }

    /// Saves `data` under `item`, replacing any existing value. For tokens and
    /// the licence record; archive keys use `add`.
    public func set(_ data: Data, for item: String) throws {
        try checkBackendAllowed()
        let status = SecItemAdd(addAttributes(item: item, data: data) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(item: item) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    /// The value saved under `item`, or nil if there is none.
    public func get(_ item: String) throws -> Data? {
        try checkBackendAllowed()
        var query = baseQuery(item: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Removes the item. Removing an item that does not exist is not an error.
    public func delete(_ item: String) throws {
        let status = SecItemDelete(baseQuery(item: item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// Names of every item under this service.
    public func items() throws -> [String] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let rows = result as? [[String: Any]] else { throw KeychainError.unexpectedData }
            return rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError(status: status)
        }
    }

    /// Removes every item under this service. Used by tests and by uninstall.
    public func deleteAll() throws {
        for item in try items() {
            try delete(item)
        }
    }

    // MARK: Queries

    func serviceQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    func baseQuery(item: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = item
        return query
    }

    /// The attributes used when creating an item. Exposed to tests so the
    /// security checklist ("ThisDeviceOnly, not synchronisable") is checked in code.
    func addAttributes(item: String, data: Data) -> [String: Any] {
        var attributes = baseQuery(item: item)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        attributes[kSecAttrLabel as String] = "Stow (\(item))"
        return attributes
    }
}
