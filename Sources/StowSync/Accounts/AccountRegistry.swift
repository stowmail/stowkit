import Foundation
import StowCore
import StowSecrets

/// Kept for code written against the Phase 1 name.
public typealias AccountRegistryError = AccountDirectoryError

/// The Phase 1 list of connected accounts, kept in the Keychain (D-100).
///
/// Each account is one Keychain item named `account.<id>`, holding the JSON of
/// an `AccountRecord`. From Phase 2 the archive's `accounts` table is the list
/// (D-032): `stowmail init` copies these records into it and then deletes
/// them, so this type remains only as the source of that one-time move and
/// for tests.
public struct AccountRegistry: AccountDirectory {
    static let itemPrefix = "account."
    public let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    static func itemName(for id: AccountID) -> String { itemPrefix + id.rawValue }

    public func all() throws -> [AccountRecord] {
        try keychain.items()
            .filter { $0.hasPrefix(Self.itemPrefix) }
            .compactMap { try keychain.get($0) }
            .map { try JSONDecoder().decode(AccountRecord.self, from: $0) }
            .sorted { ($0.addedAt, $0.account.id) < ($1.addedAt, $1.account.id) }
    }

    public func record(_ id: AccountID) throws -> AccountRecord? {
        guard let data = try keychain.get(Self.itemName(for: id)) else { return nil }
        return try JSONDecoder().decode(AccountRecord.self, from: data)
    }

    public func save(_ record: AccountRecord) throws {
        try keychain.set(try JSONEncoder().encode(record), for: Self.itemName(for: record.account.id))
    }

    public func add(_ record: AccountRecord) throws {
        let address = record.account.email.lowercased()
        if let existing = try all().first(where: {
            $0.account.provider == record.account.provider && $0.account.email.lowercased() == address
        }) {
            throw AccountDirectoryError.alreadyExists(existing.account.id)
        }
        try save(record)
    }

    public func setNeedsSignIn(_ id: AccountID, _ value: Bool) throws {
        guard var record = try record(id) else { throw AccountDirectoryError.notFound(id.rawValue) }
        guard record.needsSignIn != value else { return }
        record.needsSignIn = value
        try save(record)
    }

    /// Removes the account and its tokens from the Keychain.
    public func remove(_ id: AccountID, tokens: TokenStore) throws {
        try tokens.delete(for: id)
        try keychain.delete(Self.itemName(for: id))
    }

    /// Deletes only the account record, leaving its tokens: used once the
    /// record has been copied into the archive (D-032).
    public func forget(_ id: AccountID) throws {
        try keychain.delete(Self.itemName(for: id))
    }
}
