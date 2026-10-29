import Foundation

/// The engine's version, reported by `stowmail --version`.
public enum StowVersion {
    public static let current = "0.1.2"
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

/// Which mail provider an account belongs to. All are reached over IMAP:
/// Google and Microsoft with OAuth (D-004), iCloud with an app-specific password (D-467).
public enum Provider: String, Sendable, Codable, CaseIterable {
    /// Gmail and Google Workspace.
    case gmail
    /// Office 365, Microsoft 365 and Outlook.com.
    case microsoft
    /// iCloud Mail: @icloud.com, @me.com and @mac.com, and custom domains on iCloud+ (D-466).
    case icloud

    /// The OAuth provider behind this one, or nil for iCloud, which signs in
    /// with an app-specific password. Code that needs OAuth takes an
    /// `OAuthProvider`, so it cannot be called for iCloud at all.
    public var oauth: OAuthProvider? {
        switch self {
        case .gmail: .gmail
        case .microsoft: .microsoft
        case .icloud: nil
        }
    }

    /// How the account signs in.
    public var credentialKind: CredentialKind {
        oauth == nil ? .appSpecificPassword : .oauthTokens
    }
}

/// The providers that sign in with OAuth in the browser.
public enum OAuthProvider: String, Sendable, Codable, CaseIterable {
    case gmail
    case microsoft

    public var provider: Provider {
        switch self {
        case .gmail: .gmail
        case .microsoft: .microsoft
        }
    }
}

/// What Stow keeps in the Keychain to sign in to an account. Named in
/// `status` and `doctor`; the value itself is never shown (D-467 item 7).
public enum CredentialKind: String, Sendable, Codable {
    case oauthTokens
    case appSpecificPassword

    /// For output: "sign-in tokens" or "app-specific password".
    public var label: String {
        switch self {
        case .oauthTokens: "sign-in tokens"
        case .appSpecificPassword: "app-specific password"
        }
    }
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
