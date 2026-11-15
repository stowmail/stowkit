import Foundation
import Logging
import StowCore
@testable import StowEngine
import StowStore
import StowTestSupport
import Testing

/// R19: the app's processes give the archive, `rules.json` and the logs their app group
/// container as a base; the command-line tool's folders stay exactly as they were.
@Suite struct StowHomeTests {
    @Test func theCLIKeepsItsFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(ArchiveLocation.defaultLocation(in: .cli) == ArchiveLocation.defaultForCLI)
        #expect(ArchiveLocation.defaultForCLI.root.path == home.appendingPathComponent("Library/Application Support/Stow").path)
        #expect(EngineRules.defaultSettingsURL.path == home.appendingPathComponent("Library/Application Support/Stow/rules.json").path)
        #expect(EngineRules.settingsURL(in: .cli) == EngineRules.defaultSettingsURL)
        #expect(StowHome.cli.logFolder.path == LaunchAgent.logDirectory.path)
        #expect(LogFile.named("stowmail.log", in: .cli).url.path == LogFile.shared.url.path)
    }

    @Test func aContainerHoldsTheSameLayout() {
        let container = URL(fileURLWithPath: "/tmp/Group Containers/group.example", isDirectory: true)
        let home = StowHome.appGroup(container)
        #expect(ArchiveLocation.defaultLocation(in: home).root.path == "/tmp/Group Containers/group.example/Library/Application Support/Stow")
        #expect(EngineRules.settingsURL(in: home).path == "/tmp/Group Containers/group.example/Library/Application Support/Stow/rules.json")
        #expect(LogFile.named("stow-agent.log", in: home).url.path == "/tmp/Group Containers/group.example/Library/Logs/Stow/stow-agent.log")
    }

    /// D-514's modes hold for a log made under a container base too.
    @Test func logsUnderAContainerArePrivate() throws {
        let container = TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let file = LogFile.named("stow-agent.log", in: .appGroup(container))
        let handler = FileLogHandler(label: "test", file: file)
        Logger(label: "test") { _ in handler }.notice("started")
        let folder = try FileManager.default.attributesOfItem(atPath: file.url.deletingLastPathComponent().path)
        let log = try FileManager.default.attributesOfItem(atPath: file.url.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
        #expect((log[.posixPermissions] as? Int) == 0o600)
    }
}
