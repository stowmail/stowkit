import Foundation
import StowCore

/// An iCloud app-specific password (D-467).
///
/// Held as bytes, never as a `String` property, and it describes itself as
/// redacted everywhere: printing, logging, `dump` or string interpolation of
/// this type, or of anything holding it, shows no part of it and not its length.
public struct AppSpecificPassword: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let bytes: [UInt8]

    /// Why a typed password was refused before anything was sent.
    public enum ShapeError: Error, Equatable, CustomStringConvertible {
        case empty
        case wrongShape

        public var description: String {
            switch self {
            case .empty:
                "No app-specific password was entered. Nothing was saved."
            case .wrongShape:
                "That does not look like an app-specific password. Apple's are 16 letters in four groups, like xxxx-xxxx-xxxx-xxxx. Make one at account.apple.com (Sign-In and Security, App-Specific Passwords) and enter that, not your Apple Account password. Nothing was saved."
            }
        }
    }

    /// Checks the shape Apple issues (16 letters in four groups of four, D-467
    /// item 1), after tidying away spaces and hyphens, and keeps it in the
    /// form Apple shows it: `xxxx-xxxx-xxxx-xxxx`. Letters keep their case.
    public init(typed: String) throws {
        let letters = typed.unicodeScalars.filter { $0 != " " && $0 != "-" && $0 != "\t" }
        guard !letters.isEmpty else { throw ShapeError.empty }
        guard letters.count == 16, letters.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) else {
            throw ShapeError.wrongShape
        }
        var canonical: [UInt8] = []
        for (index, scalar) in letters.enumerated() {
            if index > 0, index % 4 == 0 { canonical.append(UInt8(ascii: "-")) }
            canonical.append(UInt8(scalar.value))
        }
        bytes = canonical
    }

    /// Bytes read back from the Keychain, which only ever holds a checked password.
    init(storedBytes: [UInt8]) {
        bytes = storedBytes
    }

    /// The password's UTF-8 bytes, for the SASL PLAIN response only.
    public func withBytes<T>(_ body: ([UInt8]) throws -> T) rethrows -> T {
        try body(bytes)
    }

    public var description: String { "AppSpecificPassword([redacted])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Per-account app-specific passwords, kept in the Keychain and nowhere else
/// (D-467 item 3), through the same `KeychainStore`, so with the same
/// attributes as OAuth tokens (D-007): this device only, after first unlock,
/// never synchronised; under `STOW_KEYCHAIN=file` the FileVault check applies (D-012).
/// A sibling of `TokenStore` rather than a second kind of value inside it (D-471).
public struct PasswordStore: Sendable {
    public let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    static func itemName(for accountID: AccountID) -> String {
        "password.\(accountID.rawValue)"
    }

    /// Saves or replaces the account's password. Call only once the server
    /// has accepted it (D-467 item 4).
    public func save(_ password: AppSpecificPassword, for accountID: AccountID) throws {
        try password.withBytes { try keychain.set(Data($0), for: Self.itemName(for: accountID)) }
    }

    /// The saved password, or nil if there is none (never added, or removed).
    public func password(for accountID: AccountID) throws -> AppSpecificPassword? {
        guard let data = try keychain.get(Self.itemName(for: accountID)) else { return nil }
        return AppSpecificPassword(storedBytes: [UInt8](data))
    }

    /// Whether a password is stored, from the Keychain's item names alone,
    /// without reading the password (for `stowmail doctor`).
    public func hasPassword(for accountID: AccountID) throws -> Bool {
        try keychain.items().contains(Self.itemName(for: accountID))
    }

    public func delete(for accountID: AccountID) throws {
        try keychain.delete(Self.itemName(for: accountID))
    }
}
