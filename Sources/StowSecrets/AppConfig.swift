import Foundation

/// The app's own OAuth client settings (D-007): which Google and Microsoft app
/// registrations Stow signs in through. Not user tokens, which live in the Keychain.
///
/// Where they come from (D-482, D-512):
/// - **A bundled-config build** (compiled with `STOW_BUNDLED_CONFIG`, as the
///   app and the CLI and MCP helper bundled with it are) uses the values built
///   in and reads no file and no environment variable.
/// - **A source build** reads the file named by `STOW_ENV_FILE`, or else
///   `~/Library/Application Support/Stow/config.env`, or neither if that does
///   not exist; environment variables override the file. Never the current folder.
///
/// Values are never logged, and errors name the key and the place, never the value.
public struct AppConfig: Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case googleClientID = "STOW_GOOGLE_CLIENT_ID"
        case googleClientSecret = "STOW_GOOGLE_CLIENT_SECRET"
        case microsoftClientID = "STOW_MS_CLIENT_ID"
        case microsoftTenant = "STOW_MS_TENANT"
    }

    /// Where a value came from. Shown by `stowmail doctor`; never the value itself.
    public enum Source: Equatable, Sendable, CustomStringConvertible {
        case builtIn
        case envFileVariable(String)
        case configFile(String)
        case environment

        public var description: String {
            switch self {
            case .builtIn: "built in"
            case .envFileVariable(let path): "STOW_ENV_FILE (\(path))"
            case .configFile(let path): "config.env (\(path))"
            case .environment: "environment"
            }
        }
    }

    public static let envFileVariable = "STOW_ENV_FILE"
    static let placeholder = "REPLACE_ME"

    /// True when this build has the client IDs compiled in.
    public static let isBundled = BundledAppConfig.values != nil

    /// The configuration file a source build reads when `STOW_ENV_FILE` is not set.
    public static func configFileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Stow/config.env")
    }

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
    ///   - home: the folder `config.env` is found under (tests pass a temporary one).
    ///   - bundled: the built-in values; nil in a source build.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundled: [String: String]? = BundledAppConfig.values
    ) throws -> AppConfig {
        let resolved = try resolve(environment: environment, home: home, bundled: bundled)
        let place = resolved.file.map(\.description) ?? (bundled == nil ? "the environment" : "this build")
        func required(_ key: Key) throws -> String {
            let value = resolved.values[key.rawValue]?.value
            switch status(of: value) {
            case .set: return value!
            case .missing: throw AppConfigError.missing(key.rawValue, bundled: bundled != nil)
            case .placeholder: throw AppConfigError.placeholder(key.rawValue, in: place)
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

    /// Whether each key is set and where from, without revealing any value. Used by `stowmail doctor`.
    public struct Report: Sendable {
        public struct Row: Sendable {
            public var key: String
            public var status: ValueStatus
            public var source: Source?
        }
        /// The file read, if any: `STOW_ENV_FILE` or `config.env`.
        public var file: Source?
        /// Built in, or read from files and the environment.
        public var bundled: Bool
        public var rows: [Row]
    }

    public static func report(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundled: [String: String]? = BundledAppConfig.values
    ) throws -> Report {
        let resolved = try resolve(environment: environment, home: home, bundled: bundled)
        let rows = Key.allCases.map { key in
            let entry = resolved.values[key.rawValue]
            return Report.Row(key: key.rawValue, status: status(of: entry?.value), source: entry?.source)
        }
        return Report(file: resolved.file, bundled: bundled != nil, rows: rows)
    }

    static func status(of value: String?) -> ValueStatus {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return .missing }
        return value.contains(placeholder) ? .placeholder : .set
    }

    /// Built-in values alone; otherwise the file, then the environment for anything it sets.
    static func resolve(environment: [String: String], home: URL, bundled: [String: String]?)
        throws -> (values: [String: (value: String, source: Source)], file: Source?) {
        if let bundled {
            return (bundled.mapValues { ($0, .builtIn) }, nil)
        }
        let file: (url: URL, source: Source)?
        if let path = environment[envFileVariable], !path.isEmpty {
            file = (URL(fileURLWithPath: path), .envFileVariable(path))
            guard FileManager.default.fileExists(atPath: path) else {
                throw AppConfigError.unreadableFile(URL(fileURLWithPath: path).lastPathComponent)
            }
        } else {
            let url = configFileURL(home: home)
            file = FileManager.default.fileExists(atPath: url.path) ? (url, .configFile(url.path)) : nil
        }
        var values: [String: (value: String, source: Source)] = [:]
        if let file {
            guard let data = FileManager.default.contents(atPath: file.url.path),
                  let text = String(data: data, encoding: .utf8)
            else { throw AppConfigError.unreadableFile(file.url.lastPathComponent) }
            values = parseEnvFile(text).mapValues { ($0, file.source) }
        }
        for key in Key.allCases {
            if let value = environment[key.rawValue] { values[key.rawValue] = (value, .environment) }
        }
        return (values, file?.source)
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
    /// `bundled`: the build was meant to have the value built in.
    case missing(String, bundled: Bool = false)
    /// `in`: where the placeholder was found, such as "config.env (/path)".
    case placeholder(String, in: String)
    case unreadableFile(String)

    public var description: String {
        switch self {
        case .missing(let key, true): "\(key) is not built into this build of Stow."
        case .missing(let key, false): "\(key) is not set. Add it to ~/Library/Application Support/Stow/config.env (copy .env.example), or name another file with STOW_ENV_FILE."
        case .placeholder(let key, let place): "\(key) still has its REPLACE_ME placeholder in \(place). Fill it in there."
        case .unreadableFile(let name): "Could not read the configuration file \(name)."
        }
    }
}
