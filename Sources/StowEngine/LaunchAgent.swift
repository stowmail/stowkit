import Foundation
import StowSecrets

public enum LaunchAgentError: Error, Equatable, CustomStringConvertible {
    case launchctlFailed(String)

    public var description: String {
        switch self {
        case .launchctlFailed(let detail): "launchctl could not load the background sync: \(detail)"
        }
    }
}

/// The background sync as a launchd user agent (step 5, D-037):
/// `stowmail daemon install` writes the plist and loads it; `uninstall`
/// unloads and deletes it.
///
/// The agent starts at login, restarts after a crash (not after a clean
/// exit), and runs with `ProcessType` Background, `Nice` 10 and low-priority
/// I/O, so macOS gives it whatever the user is not using. The plist holds no
/// secrets: only the executable's path and a short list of settings (D-037),
/// all of them paths or switches. Client IDs stay in the configuration file
/// (`STOW_ENV_FILE` or `config.env`, D-512) or are built in,
/// tokens and keys in the Keychain.
public enum LaunchAgent {
    public static let label = "ee.getstow.stowmail.daemon"

    /// The only environment variables copied into the plist. None holds a secret.
    public static let allowedEnvironment = ["STOW_KEYCHAIN", "STOW_ENV_FILE", "STOW_ARCHIVE_DIR", "STOW_KEYCHAIN_SERVICE", "STOW_LOG_LEVEL"]

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Stow", isDirectory: true)
    }

    /// Where `install` puts the copy of `stowmail` (with its frameworks and resource bundles) that launchd runs. A build
    /// replaces the file in `.build`, and with the file-based Keychain (D-012)
    /// macOS trusts one exact binary, so running the build output would make
    /// every rebuild ask for the login password again.
    public static var installedExecutable: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ee.getstow.dev/bin/stowmail")
    }

    public static var outputLog: URL { logDirectory.appendingPathComponent("daemon.out.log") }

    /// The plist's contents. Environment variables outside `allowedEnvironment` are dropped.
    public static func plist(executable: URL, environment: [String: String]) -> [String: Any] {
        let kept = environment.filter { allowedEnvironment.contains($0.key) && !$0.value.isEmpty }
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "daemon", "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "Nice": 10,
            "LowPriorityIO": true,
            "LowPriorityBackgroundIO": true,
            "ThrottleInterval": 60,
            "StandardOutPath": outputLog.path,
            "StandardErrorPath": outputLog.path,
        ]
        if !kept.isEmpty { plist["EnvironmentVariables"] = kept }
        return plist
    }

    /// The settings the installed agent runs with, or none if it is not installed.
    public static func installedEnvironment(plist url: URL = plistURL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist["EnvironmentVariables"] as? [String: String] ?? [:]
    }

    /// What changed between the agent being replaced and the new one.
    public struct SettingsChange: Sendable, Equatable {
        public var kept: [String] = []
        public var changed: [String] = []
        public var removed: [String] = []
    }

    /// The settings for a reinstall. A setting the old agent had is kept unless
    /// this shell sets it, and set but empty removes it, so reinstalling from a
    /// shell without `STOW_KEYCHAIN` cannot silently switch keychains (D-082).
    public static func reinstallEnvironment(current: [String: String], previous: [String: String])
        -> (environment: [String: String], change: SettingsChange) {
        var environment = current.filter { allowedEnvironment.contains($0.key) }
        var change = SettingsChange()
        for key in allowedEnvironment {
            let old = previous[key].flatMap { $0.isEmpty ? nil : $0 }
            switch (old, environment[key]) {
            case (let old?, nil):
                environment[key] = old
                change.kept.append("\(key)=\(old)")
            case (let old?, let new?) where new.isEmpty:
                change.removed.append("\(key)=\(old)")
            case (let old?, let new?) where new != old:
                change.changed.append("\(key): \(old) to \(new)")
            default:
                break
            }
        }
        return (environment.filter { !$0.value.isEmpty }, change)
    }

    /// What `daemon install` writes, and what it tells the user about it.
    public struct InstallPlan: Sendable, Equatable {
        public var environment: [String: String]
        public var change: SettingsChange
        public var notes: [String] = []
    }

    /// The settings `daemon install` gives the agent, from this shell's and the
    /// previous agent's (D-512). Configuration is never taken from the current
    /// folder. A saved `STOW_ENV_FILE` that still exists is kept (the shell can
    /// still change or empty it); one that no longer exists is dropped, so the
    /// agent falls back to `config.env`. A bundled-config build names no file.
    /// No configuration file is ever copied or rewritten.
    public static func installEnvironment(
        shell: [String: String],
        previous: [String: String],
        bundled: Bool = AppConfig.isBundled,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> InstallPlan {
        let key = AppConfig.envFileVariable
        var current = shell.filter { allowedEnvironment.contains($0.key) }
        var notes: [String] = []
        var dropped: String?
        if bundled {
            current[key] = ""
        } else if current[key] == nil, let saved = previous[key], !saved.isEmpty, !fileExists(saved) {
            current[key] = ""
            dropped = saved
        }
        var (environment, change) = reinstallEnvironment(current: current, previous: previous)
        if bundled {
            notes.append("App configuration: built in to this build, so the agent names no configuration file.")
        } else if let path = environment[key] {
            notes.append("App configuration: from STOW_ENV_FILE (\(path)).")
        } else {
            let configFile = "\(AppConfig.configFileURL(home: home).path) (config.env) if present, else the environment"
            notes.append(dropped.map { "STOW_ENV_FILE (\($0)) no longer exists, so the agent no longer names it. App configuration: from \(configFile)." }
                ?? "App configuration: from \(configFile).")
        }
        change.removed.sort()
        return InstallPlan(environment: environment, change: change, notes: notes)
    }

    public static func encoded(executable: URL, environment: [String: String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(executable: executable, environment: environment), format: .xml, options: 0)
    }

    /// Copies `executable` to `installedExecutable`, writes the plist (0644, as
    /// launchd expects) and loads it, replacing any earlier copy.
    public static func install(executable: URL, environment: [String: String]) throws {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isLoaded() {
            _ = try? launchctl(["bootout", "gui/\(getuid())/\(label)"])
            // bootout returns before the agent is gone; bootstrapping too soon fails with error 5.
            for _ in 0..<50 where isLoaded() { usleep(200_000) }
        }
        try copyExecutable(executable, to: installedExecutable)
        try createPrivateFile(outputLog)
        try encoded(executable: installedExecutable, environment: environment).write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        let (status, output) = try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard status == 0 else { throw LaunchAgentError.launchctlFailed(output) }
    }

    /// Unloads the agent and deletes the plist and the copied binary. The archive is left exactly as it is.
    public static func uninstall() throws {
        if isLoaded() { _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
        let folder = installedExecutable.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    /// Copies the binary, and the frameworks and resource bundles beside it
    /// (SQLCipher, which it loads from `@loader_path`, and SwiftPM's resource
    /// bundles, such as the rules), into a fresh folder, then swaps that folder
    /// into place. Same bytes, same code signature.
    static func copyExecutable(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let folder = destination.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".\(folder.lastPathComponent).\(UUID().uuidString)")
        let retired = parent.appendingPathComponent(".\(folder.lastPathComponent).old.\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try manager.copyItem(at: source, to: staging.appendingPathComponent(destination.lastPathComponent))
            for name in try manager.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
            where name.hasSuffix(".framework") || name.hasSuffix(".bundle") {
                try manager.copyItem(at: source.deletingLastPathComponent().appendingPathComponent(name),
                                     to: staging.appendingPathComponent(name))
            }
            if manager.fileExists(atPath: folder.path) { try manager.moveItem(at: folder, to: retired) }
            try manager.moveItem(at: staging, to: folder)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        try? manager.removeItem(at: retired)
    }

    /// launchd appends to an existing file and keeps its mode, so create it 0600 first.
    static func createPrivateFile(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    public static func isLoaded() -> Bool {
        ((try? launchctl(["print", "gui/\(getuid())/\(label)"]))?.status ?? 1) == 0
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Puts this process in the background band: lower CPU and I/O priority,
    /// on top of what launchd's `ProcessType` does (D-037).
    public static func lowerPriority() {
        setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
    }
}
