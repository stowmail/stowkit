import Foundation

/// The base folder Stow's own files hang from (R19, D-060): the user's home folder for the
/// command-line tool, the app group container for the app's processes. Under it, the layout
/// is the same either way:
///
/// ```
/// Library/Application Support/Stow/   the default archive and rules.json
/// Library/Logs/Stow/                  stowmail.log and the other logs, mcp-audit.log
/// ```
///
/// The CLI's paths are unchanged by this type: `.cli` gives exactly the folders it always used.
/// A sandboxed process must pass its app group container explicitly, because its own home
/// folder is its private container, where the other two processes cannot see anything.
public struct StowHome: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The user's home folder: what the command-line tool and the background sync it installs use.
    public static var cli: StowHome {
        StowHome(root: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// An app group container, as `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` gives it.
    public static func appGroup(_ container: URL) -> StowHome {
        StowHome(root: container)
    }

    /// `Library/Application Support/Stow`: the default archive folder, with `rules.json` in it.
    public var supportFolder: URL {
        root.appendingPathComponent("Library/Application Support/Stow", isDirectory: true)
    }

    /// `Library/Logs/Stow`: every log Stow writes, and the MCP audit log.
    public var logFolder: URL {
        root.appendingPathComponent("Library/Logs/Stow", isDirectory: true)
    }

    /// Rule switches and weights (D-304).
    public var rulesURL: URL {
        supportFolder.appendingPathComponent("rules.json")
    }
}
