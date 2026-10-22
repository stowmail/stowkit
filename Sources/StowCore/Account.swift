import Foundation

/// The engine's version, reported by `stowmail --version`.
public enum StowVersion {
    public static let current = "0.1.0"
}

/// Stable identifier for a mail account inside one Stow install.
///
/// A random UUID string chosen when the account is added. It never contains
/// the email address, so it is safe to use in file paths, Keychain account
/// names and logs.
public struct AccountID: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new random identifier.
    public static func generate() -> AccountID {
        AccountID(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }

    public static func < (lhs: AccountID, rhs: AccountID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Which mail provider an account belongs to. Both are reached over IMAP with OAuth (D-004).
public enum Provider: String, Sendable, Codable, CaseIterable {
    /// Gmail and Google Workspace.
    case gmail
    /// Office 365, Microsoft 365 and Outlook.com.
    case microsoft
}

/// One mailbox the user has connected.
public struct Account: Hashable, Sendable, Codable, Identifiable {
    public let id: AccountID
    public let provider: Provider
    /// The mailbox address. Never log it unhashed (see `Redact.address`).
    public var email: String
    /// A friendly name chosen by the user, for example "Work".
    public var displayName: String

    public init(id: AccountID, provider: Provider, email: String, displayName: String) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName
    }
}

/// A single mailbox address with an optional display name, as found in headers
/// such as From and To.
public struct EmailAddress: Hashable, Sendable, Codable {
    /// Display name with any RFC 2047 encoding already decoded, for example "Sam Taylor".
    public var name: String?
    /// The addr-spec, for example "sam@example.com". Kept as written; compare with `normalised`.
    public var address: String

    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }

    /// Lowercased, trimmed address used for comparison and deduplication.
    public var normalised: String {
        address.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The part after the last "@", lowercased. Empty if there is no "@".
    public var domain: String {
        guard let at = normalised.lastIndex(of: "@") else { return "" }
        return String(normalised[normalised.index(after: at)...])
    }

    /// The part before the last "@", lowercased.
    public var localPart: String {
        guard let at = normalised.lastIndex(of: "@") else { return normalised }
        return String(normalised[..<at])
    }
}
