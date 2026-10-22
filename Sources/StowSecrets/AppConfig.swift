import Foundation

/// The app's own OAuth client settings (D-007): which Google and Microsoft app
/// registrations Stow signs in through. Not user tokens, which live in the Keychain.
///
/// Values come from the process environment first, then from a `.env` file:
/// the path in `STOW_ENV_FILE`, or `.env` in the current directory (normally
/// `engine/`). Values are never logged, and errors name the key, never the value.
public struct AppConfig: Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case googleClientID = "STOW_GOOGLE_CLIENT_ID"
        case googleClientSecret = "STOW_GOOGLE_CLIENT_SECRET"
        case microsoftClientID = "STOW_MS_CLIENT_ID"
        case microsoftTenant = "STOW_MS_TENANT"
    }

    public static let envFileVariable = "STOW_ENV_FILE"
    static let placeholder = "REPLACE_ME"

    public let googleClientID: String
    /// Google issues a "secret" even for desktop apps. It is not confidential
    /// (anyone can extract it from a shipped app), but it stays out of git.
    public let googleClientSecret: String
    public let microsoftClientID: String
    public let microsoftTenant: String

    /// Loads and validates every key.
    ///
    /// - Parameters:
    ///   - environment: usually the process environment.
    ///   - currentDirectory: where to look for `.env` when `STOW_ENV_FILE` is not set.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> AppConfig {
        let values = try resolve(environment: environment, currentDirectory: currentDirectory)
        func required(_ key: Key) throws -> String {
            switch status(of: values[key.rawValue]) {
            case .set: return values[key.rawValue]!
            case .missing: throw AppConfigError.missing(key.rawValue)
            case .placeholder: throw AppConfigError.placeholder(key.rawValue)
            }
        }
        return AppConfig(
            googleClientID: try required(.googleClientID),
            googleClientSecret: try required(.googleClientSecret),
            microsoftClientID: try required(.microsoftClientID),
            microsoftTenant: try required(.microsoftTenant)
        )
    }

    public enum ValueStatus: String, Sendable {
        case set, missing, placeholder
    }

    /// Whether each key is set, without revealing any value. Used by `stowmail config check`.
    public static func report(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> [(key: String, status: ValueStatus)] {
        let values = try resolve(environment: environment, currentDirectory: currentDirectory)
        return Key.allCases.map { ($0.rawValue, status(of: values[$0.rawValue])) }
    }

    static func status(of value: String?) -> ValueStatus {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return .missing }
        return value.contains(placeholder) ? .placeholder : .set
    }

    /// Environment first, then the `.env` file for anything not set in the environment.
    static func resolve(environment: [String: String], currentDirectory: URL) throws -> [String: String] {
        let fileURL = environment[envFileVariable].map { URL(fileURLWithPath: $0) }
            ?? currentDirectory.appendingPathComponent(".env")
        var values: [String: String] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = FileManager.default.contents(atPath: fileURL.path),
                  let text = String(data: data, encoding: .utf8)
            else { throw AppConfigError.unreadableFile(fileURL.lastPathComponent) }
            values = parseEnvFile(text)
        } else if environment[envFileVariable] != nil {
            throw AppConfigError.unreadableFile(fileURL.lastPathComponent)
        }
        for key in Key.allCases {
            if let value = environment[key.rawValue] { values[key.rawValue] = value }
        }
        return values
    }

    /// Parses `KEY=value` lines. Ignores blank lines and `#` comments, accepts an
    /// optional `export ` prefix and strips matching single or double quotes.
    static func parseEnvFile(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}

public enum AppConfigError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case placeholder(String)
    case unreadableFile(String)

    public var description: String {
        switch self {
        case .missing(let key): "\(key) is not set. Add it to engine/.env or the environment."
        case .placeholder(let key): "\(key) still has its REPLACE_ME placeholder. Fill it in engine/.env."
        case .unreadableFile(let name): "Could not read the configuration file \(name)."
        }
    }
}
