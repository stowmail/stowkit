import Foundation

/// One connected account plus Stow's own bookkeeping about it.
public struct AccountRecord: Codable, Sendable, Equatable {
    public var account: Account
    /// Set when the provider rejects the refresh token (`invalid_grant`). Sync
    /// refuses to run until the user signs in again; it never retries in a loop.
    public var needsSignIn: Bool
    public var addedAt: Date
    /// Set when the user removed the account: it no longer syncs and its
    /// tokens are gone, but its archived mail is kept (D-032).
    public var disconnectedAt: Date?

    public init(account: Account, needsSignIn: Bool = false, addedAt: Date = Date(), disconnectedAt: Date? = nil) {
        self.account = account
        self.needsSignIn = needsSignIn
        self.addedAt = addedAt
        self.disconnectedAt = disconnectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case account, needsSignIn, addedAt, disconnectedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(Account.self, forKey: .account)
        needsSignIn = try container.decode(Bool.self, forKey: .needsSignIn)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        disconnectedAt = try container.decodeIfPresent(Date.self, forKey: .disconnectedAt)
    }

    public var isConnected: Bool { disconnectedAt == nil }
}

public enum AccountDirectoryError: Error, Equatable, CustomStringConvertible {
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

/// Where the list of accounts is kept: the Keychain during Phase 1 (D-100),
/// the archive's `accounts` table from Phase 2 (D-032).
public protocol AccountDirectory: Sendable {
    /// Every account, oldest first, including disconnected ones.
    func all() throws -> [AccountRecord]
    func record(_ id: AccountID) throws -> AccountRecord?
    /// Adds a new account, refusing a second copy of the same provider and address.
    func add(_ record: AccountRecord) throws
    func setNeedsSignIn(_ id: AccountID, _ value: Bool) throws
}

extension AccountDirectory {
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
        case 0: throw AccountDirectoryError.notFound(query)
        default: throw AccountDirectoryError.ambiguous(query)
        }
    }

    /// Accounts that sync: connected ones.
    public func connected() throws -> [AccountRecord] {
        try all().filter(\.isConnected)
    }
}
