import Foundation

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
/// all of them paths or switches. Client IDs stay in the `.env` file it names,
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

    /// Where `install` puts the copy of `stowmail` that launchd runs. A build
    /// replaces the file in `.build`, and with the file-based Keychain (D-012)
    /// macOS trusts one exact binary, so running the build output would make
    /// every rebuild ask for the login password again.
    public static var installedExecutable: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ee.getstow.dev/bin/stowmail")
    }

    static var outputLog: URL { logDirectory.appendingPathComponent("daemon.out.log") }

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

    public static func encoded(executable: URL, environment: [String: String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(executable: executable, environment: environment), format: .xml, options: 0)
    }

    /// Copies `executable` to `installedExecutable`, writes the plist (0644, as
    /// launchd expects) and loads it, replacing any earlier copy.
    public static func install(executable: URL, environment: [String: String]) throws {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isLoaded() { _ = try? launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
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
        if FileManager.default.fileExists(atPath: installedExecutable.path) { try FileManager.default.removeItem(at: installedExecutable) }
    }

    /// Copies the binary beside its destination, then moves it into place in one
    /// step, so a running copy is never overwritten in place. Same bytes, same
    /// code signature.
    static func copyExecutable(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        try manager.copyItem(at: source, to: staging)
        guard rename(staging.path, destination.path) == 0 else {
            try? manager.removeItem(at: staging)
            throw CocoaError(.fileWriteUnknown)
        }
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
