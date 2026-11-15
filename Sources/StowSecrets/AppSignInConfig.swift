import Foundation

/// The Mac app's own sign-in clients (R21, D-554, D-677): Google's iOS-type client for the app's
/// bundle ID (no secret; its reversed client ID is the redirect scheme) and the Microsoft
/// registration the CLI uses, whose redirect for the app is `msauth.<bundle ID>://auth`.
///
/// Read like `AppConfig` (D-512): built in for a release build (step 7); in a signed debug build
/// from the login item's own `config.env`, which in the sandbox is inside its container
/// (D-641). Only the login item reads it, since only it signs in and refreshes tokens (D-646).
/// Values are never logged; errors name the key and the place, never the value.
public struct AppSignInConfig: Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case googleClientID = "STOW_APP_GOOGLE_CLIENT_ID"
        case microsoftClientID = "STOW_MS_CLIENT_ID"
        case microsoftTenant = "STOW_MS_TENANT"
    }

    public let googleClientID: String
    public let microsoftClientID: String
    public let microsoftTenant: String

    public init(googleClientID: String, microsoftClientID: String, microsoftTenant: String) {
        self.googleClientID = googleClientID
        self.microsoftClientID = microsoftClientID
        self.microsoftTenant = microsoftTenant
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundled: [String: String]? = BundledAppConfig.values
    ) throws -> AppSignInConfig {
        let resolved = try AppConfig.resolve(environment: environment, home: home, bundled: bundled, keys: Key.allCases.map(\.rawValue))
        let place = resolved.file.map(\.description) ?? (bundled == nil ? "the environment" : "this build")
        func required(_ key: Key) throws -> String {
            let value = resolved.values[key.rawValue]?.value
            switch AppConfig.status(of: value) {
            case .set: return value!
            case .missing: throw AppConfigError.missing(key.rawValue, bundled: bundled != nil)
            case .placeholder: throw AppConfigError.placeholder(key.rawValue, in: place)
            }
        }
        return AppSignInConfig(googleClientID: try required(.googleClientID), microsoftClientID: try required(.microsoftClientID),
                               microsoftTenant: try required(.microsoftTenant))
    }

    /// Google's redirect for an iOS-type client: its reversed client ID as the scheme.
    /// `123-abc.apps.googleusercontent.com` gives `com.googleusercontent.apps.123-abc`.
    public var googleRedirectScheme: String {
        googleClientID.split(separator: ".").reversed().joined(separator: ".")
    }
}
