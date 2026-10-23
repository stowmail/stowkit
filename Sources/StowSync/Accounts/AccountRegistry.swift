import Foundation
import StowCore
import StowSecrets

/// One connected account plus Stow's own bookkeeping about it.
public struct AccountRecord: Codable, Sendable, Equatable {
    public var account: Account
    /// Set when the provider rejects the refresh token (`invalid_grant`). Sync
    /// refuses to run until the user signs in again; it never retries in a loop.
    public var needsSignIn: Bool
    public var addedAt: Date

    public init(account: Account, needsSignIn: Bool = false, addedAt: Date = Date()) {
        self.account = account
        self.needsSignIn = needsSignIn
        self.addedAt = addedAt
    }
}

public enum AccountRegistryError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String)
    case alreadyExists(AccountID)

    public var description: String {
        switch self {
        case .notFound: "No account matches that name. See `stowmail account list`."
        case .ambiguous: "More than one account matches. Use the full account ID from `stowmail account list`."
        case .alreadyExists(let id): "That address is already added as account \(id)."
        }
    }
}

/// The list of connected accounts, kept in the Keychain until Phase 2 moves it
/// into the encrypted database's `accounts` table (D-100).
///
/// Each account is one Keychain item named `account.<id>`, holding the JSON of
/// an `AccountRecord`. Keeping it in the Keychain means no plain-text file on
/// disk lists the user's email addresses.
public struct AccountRegistry: Sendable {
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

    /// Adds a new account, refusing a second copy of the same provider and address.
    public func add(_ record: AccountRecord) throws {
        let address = record.account.email.lowercased()
        if let existing = try all().first(where: {
            $0.account.provider == record.account.provider && $0.account.email.lowercased() == address
        }) {
            throw AccountRegistryError.alreadyExists(existing.account.id)
        }
        try save(record)
    }

    public func setNeedsSignIn(_ id: AccountID, _ value: Bool) throws {
        guard var record = try record(id) else { throw AccountRegistryError.notFound(id.rawValue) }
        guard record.needsSignIn != value else { return }
        record.needsSignIn = value
        try save(record)
    }

    /// Removes the account and its tokens from the Keychain.
    public func remove(_ id: AccountID, tokens: TokenStore) throws {
        try tokens.delete(for: id)
        try keychain.delete(Self.itemName(for: id))
    }

    /// Finds an account by full ID, a unique ID prefix of at least four
    /// characters, the address, or the display name (case-insensitive).
    public func find(_ query: String) throws -> AccountRecord {
        let records = try all()
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = records.first(where: { $0.account.id.rawValue == needle }) { return exact }
        var matches = records.filter {
            $0.account.email.lowercased() == needle || $0.account.displayName.lowercased() == needle
        }
        if matches.isEmpty, needle.count >= 4 {
            matches = records.filter { $0.account.id.rawValue.hasPrefix(needle) }
        }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw AccountRegistryError.notFound(query)
        default: throw AccountRegistryError.ambiguous(query)
        }
    }
}
