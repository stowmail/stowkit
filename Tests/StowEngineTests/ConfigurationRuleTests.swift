import Foundation
@testable import StowEngine
import StowSecrets
import Testing

/// A-08 (D-482, D-512): `daemon install` no longer saves `./.env` for the agent,
/// keeps a saved path that still exists, and a bundled-config build saves none.
/// Uses temporary folders only, never the installed plist.
@Suite(.serialized) struct DaemonInstallConfigurationTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("stow-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func inFolderWithDotEnv<T>(_ body: () throws -> T) throws -> T {
        try "STOW_GOOGLE_CLIENT_ID=stranger\n".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(folder.path)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        return try body()
    }

    @Test func aDotEnvInTheCurrentFolderIsNotSaved() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = try inFolderWithDotEnv {
            LaunchAgent.installEnvironment(shell: ["STOW_KEYCHAIN": "file"], previous: [:])
        }
        #expect(plan.environment == ["STOW_KEYCHAIN": "file"])
    }

    /// The live agent's shape: `STOW_ENV_FILE` named explicitly in its plist. A
    /// reinstall from a shell without it keeps it, unchanged.
    @Test func theLiveAgentsExplicitPathIsKept() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("engine.env")
        try "STOW_MS_TENANT=common\n".write(to: saved, atomically: true, encoding: .utf8)
        let previous = ["STOW_KEYCHAIN": "file", "STOW_ENV_FILE": saved.path]
        let plan = try inFolderWithDotEnv {
            LaunchAgent.installEnvironment(shell: ["STOW_KEYCHAIN": "file"], previous: previous)
        }
        #expect(plan.environment == previous)
        #expect(plan.change.kept.contains("STOW_ENV_FILE=\(saved.path)"))
        #expect(plan.notes.contains { $0.contains("STOW_ENV_FILE") && $0.contains(saved.path) })
    }

    @Test func aSavedPathThatNoLongerExistsIsDropped() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let gone = folder.appendingPathComponent("gone/.env").path
        let plan = LaunchAgent.installEnvironment(shell: [:], previous: ["STOW_KEYCHAIN": "file", "STOW_ENV_FILE": gone])
        #expect(plan.environment == ["STOW_KEYCHAIN": "file"])
        #expect(plan.change.removed == ["STOW_ENV_FILE=\(gone)"])
        #expect(plan.notes.contains { $0.contains("no longer exists") && $0.contains("config.env") })
    }

    @Test func aBundledBuildSavesNoPath() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("engine.env")
        try "STOW_MS_TENANT=common\n".write(to: saved, atomically: true, encoding: .utf8)
        let plan = LaunchAgent.installEnvironment(
            shell: ["STOW_ENV_FILE": saved.path], previous: ["STOW_KEYCHAIN": "file", "STOW_ENV_FILE": saved.path], bundled: true)
        #expect(plan.environment == ["STOW_KEYCHAIN": "file"])
        #expect(plan.change.removed == ["STOW_ENV_FILE=\(saved.path)"])
        #expect(plan.notes.contains { $0.contains("built in") })
    }
}
