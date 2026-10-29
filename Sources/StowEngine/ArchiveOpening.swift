import Foundation
import StowCore
import StowSecrets
import StowStore

public enum ArchiveOpeningError: Error, Equatable, CustomStringConvertible {
    /// No archive at the location, and nothing says one should be there (D-082:
    /// distinct from `ArchiveLocationError.offline` and from missing keys).
    case noArchive(String)

    public var description: String {
        switch self {
        case .noArchive(let path): "There is no Stow archive at \(path)."
        }
    }
}

/// Opening an existing archive, shared by the CLI and the app (D-411): the
/// location from `STOW_ARCHIVE_DIR`, else the folder chosen with
/// `stowmail archive-location`, else the CLI default; keys from the Keychain
/// under `STOW_KEYCHAIN_SERVICE` if set (D-208, D-035).
///
/// Never creates an archive or keys. The three ways it can fail are separate
/// errors, so each gets its own message (D-082): no archive
/// (`ArchiveOpeningError.noArchive`), a chosen folder that is not there
/// (`ArchiveLocationError.offline`, usually a disconnected disk), and missing
/// keys (`KeyManagerError.keysMissing`).
public enum ArchiveOpening {
    /// The Keychain under `STOW_KEYCHAIN_SERVICE` if set, so development and
    /// tests keep their keys and tokens apart from the real ones (D-208).
    public static func keychain(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> KeychainStore {
        let service = environment["STOW_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 } ?? KeychainStore.defaultService
        return KeychainStore(service: service)
    }

    /// Checks the location without opening anything: `noArchive` or `offline` if
    /// there is no database. A missing archive at a chosen folder is "offline",
    /// not a reason to start afresh.
    public static func requireArchive(
        at location: ArchiveLocation,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: ArchiveSettings = ArchiveSettings()
    ) throws {
        // Before "no archive": the old copy may have been deleted after a move.
        try location.refuseIfMoved()
        guard !location.exists else { return }
        let fromEnvironment = environment["STOW_ARCHIVE_DIR"].map { !$0.isEmpty } ?? false
        if settings.chosenFolder != nil, !fromEnvironment { throw ArchiveLocationError.offline(location.root.path) }
        throw ArchiveOpeningError.noArchive(location.root.path)
    }

    /// Opens the archive at `location` (from the environment by default) with
    /// both keys. `readOnly` opens the database with SQLite's read-only flag
    /// and prepares nothing on disk (`Archive.open`).
    public static func openExisting(
        location: ArchiveLocation = ArchiveLocation.fromEnvironment(),
        keys: KeyManager = KeyManager(keychain: keychain()),
        readOnly: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: ArchiveSettings = ArchiveSettings()
    ) throws -> Archive {
        try requireArchive(at: location, environment: environment, settings: settings)
        return try Archive.open(location, keys: try keys.loadKeys(), readOnly: readOnly)
    }
}
