import Foundation
import Testing
@testable import StowSecrets

/// Uses fake values only and a temporary home. Never reads the real
/// engine/.env or config.env. Serialized: one test changes the current folder.
@Suite(.serialized) struct AppConfigTests {
    /// A temporary home folder: `config.env` lives under it.
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes the home's `config.env`.
    func writeEnv(_ text: String) throws {
        let url = AppConfig.configFileURL(home: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    let complete = """
    # comment
    STOW_GOOGLE_CLIENT_ID=fake-google-id.apps.googleusercontent.com
    export STOW_GOOGLE_CLIENT_SECRET="fake-google-secret"
    STOW_MS_CLIENT_ID='fake-ms-id'

    STOW_MS_TENANT=common
    """

    @Test func loadsFromEnvFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv(complete)
        let config = try AppConfig.load(environment: [:], home: directory, bundled: nil)
        #expect(config.googleClientID == "fake-google-id.apps.googleusercontent.com")
        #expect(config.googleClientSecret == "fake-google-secret")
        #expect(config.microsoftClientID == "fake-ms-id")
        #expect(config.microsoftTenant == "common")
    }

    @Test func environmentWinsOverFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv(complete)
        let config = try AppConfig.load(environment: ["STOW_MS_TENANT": "organizations"], home: directory, bundled: nil)
        #expect(config.microsoftTenant == "organizations")
    }

    @Test func envFileVariableOverridesLocation() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = directory.appendingPathComponent("custom.env")
        try complete.write(to: other, atomically: true, encoding: .utf8)
        try writeEnv(complete.replacingOccurrences(of: "fake-ms-id", with: "config-env-id"))
        let config = try AppConfig.load(environment: ["STOW_ENV_FILE": other.path], home: directory, bundled: nil)
        #expect(config.microsoftClientID == "fake-ms-id")

        #expect(throws: AppConfigError.unreadableFile("missing.env")) {
            try AppConfig.load(environment: ["STOW_ENV_FILE": directory.appendingPathComponent("missing.env").path], home: directory, bundled: nil)
        }
    }

    @Test func worksFromEnvironmentAlone() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "STOW_GOOGLE_CLIENT_ID": "g", "STOW_GOOGLE_CLIENT_SECRET": "s",
            "STOW_MS_CLIENT_ID": "m", "STOW_MS_TENANT": "common",
        ]
        #expect(try AppConfig.load(environment: environment, home: directory, bundled: nil).googleClientID == "g")
    }

    @Test func missingKeyNamesTheKeyOnly() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv(complete.replacingOccurrences(of: "STOW_MS_CLIENT_ID='fake-ms-id'", with: ""))
        #expect(throws: AppConfigError.missing("STOW_MS_CLIENT_ID", bundled: false)) {
            try AppConfig.load(environment: [:], home: directory, bundled: nil)
        }
    }

    @Test func placeholderIsRejectedWithoutShowingTheValue() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv(complete.replacingOccurrences(of: "fake-google-id", with: "REPLACE_ME"))
        do {
            _ = try AppConfig.load(environment: [:], home: directory, bundled: nil)
            Issue.record("expected an error")
        } catch let error as AppConfigError {
            #expect(error == .placeholder("STOW_GOOGLE_CLIENT_ID", in: "config.env (\(AppConfig.configFileURL(home: directory).path))"))
            #expect(!error.description.contains("googleusercontent"))
            #expect(error.description.contains("config.env"))
        }
    }

    @Test func errorsNeverContainValues() {
        for error in [AppConfigError.missing("K"), .missing("K", bundled: true), .placeholder("K", in: "config.env (/x)"), .unreadableFile(".env")] {
            #expect(!error.description.contains("fake"))
            #expect(!error.description.contains("engine/.env"))
        }
        #expect(AppConfigError.missing("K").description.contains("config.env"))
    }

    @Test func reportShowsStatusNotValues() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv("STOW_GOOGLE_CLIENT_ID=REPLACE_ME.apps.googleusercontent.com\nSTOW_MS_TENANT=common\n")
        let report = try AppConfig.report(environment: ["STOW_MS_CLIENT_ID": "m"], home: directory, bundled: nil)
        let statuses = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.key, $0.status) })
        #expect(statuses["STOW_GOOGLE_CLIENT_ID"] == .placeholder)
        #expect(statuses["STOW_GOOGLE_CLIENT_SECRET"] == .missing)
        #expect(statuses["STOW_MS_TENANT"] == .set)
        let path = AppConfig.configFileURL(home: directory).path
        #expect(report.file == .configFile(path))
        #expect(report.rows.first { $0.key == "STOW_MS_CLIENT_ID" }?.source == .environment)
        #expect(report.rows.first { $0.key == "STOW_MS_TENANT" }?.source == .configFile(path))
        #expect(!report.bundled)
    }

    @Test func matchesTheCommittedExampleKeys() throws {
        // engine/.env.example is safe to read: it holds placeholders only.
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".env.example")
        let keys = Set(AppConfig.parseEnvFile(try String(contentsOf: example, encoding: .utf8)).keys)
        #expect(keys == Set(AppConfig.Key.allCases.map(\.rawValue)))
    }

    /// A-08: a `.env` in the current folder (someone else's IDs, say in a
    /// downloaded folder) is never read; `config.env` under home is. The old
    /// code read it (throwaway test, recorded in the build log).
    @Test func aDotEnvInTheCurrentFolderIsIgnored() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloaded = directory.appendingPathComponent("downloaded")
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        try complete.replacingOccurrences(of: "fake-ms-id", with: "stranger-id")
            .write(to: downloaded.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(downloaded.path)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }

        #expect(throws: AppConfigError.missing("STOW_GOOGLE_CLIENT_ID", bundled: false)) {
            try AppConfig.load(environment: [:], home: directory, bundled: nil)
        }
        try writeEnv(complete)
        #expect(try AppConfig.load(environment: [:], home: directory, bundled: nil).microsoftClientID == "fake-ms-id")
    }

    /// A bundled-config build ignores every file and environment variable.
    @Test func builtInValuesIgnoreFilesAndEnvironment() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv(complete.replacingOccurrences(of: "fake-ms-id", with: "config-env-id"))
        let other = directory.appendingPathComponent("custom.env")
        try complete.replacingOccurrences(of: "fake-ms-id", with: "env-file-id").write(to: other, atomically: true, encoding: .utf8)
        let builtIn = ["STOW_GOOGLE_CLIENT_ID": "built-g", "STOW_GOOGLE_CLIENT_SECRET": "built-s", "STOW_MS_CLIENT_ID": "built-m", "STOW_MS_TENANT": "common"]
        let environment = ["STOW_ENV_FILE": other.path, "STOW_MS_CLIENT_ID": "environment-id", "STOW_GOOGLE_CLIENT_ID": "environment-g"]
        let config = try AppConfig.load(environment: environment, home: directory, bundled: builtIn)
        #expect(config.microsoftClientID == "built-m")
        #expect(config.googleClientID == "built-g")
        // Even a STOW_ENV_FILE naming a file that does not exist is not looked at.
        #expect(try AppConfig.load(environment: ["STOW_ENV_FILE": "/nonexistent/.env"], home: directory, bundled: builtIn).googleClientID == "built-g")
        let report = try AppConfig.report(environment: environment, home: directory, bundled: builtIn)
        #expect(report.bundled && report.file == nil)
        #expect(report.rows.allSatisfy { $0.source == .builtIn && $0.status == .set })
    }

    /// A plain `swift build` (as `check` runs) has no built-in values.
    @Test func thisBuildIsASourceBuild() {
        #expect(BundledAppConfig.values == nil)
        #expect(!AppConfig.isBundled)
    }

    @Test func sourcesAreNamedWithoutValues() {
        #expect(AppConfig.Source.builtIn.description == "built in")
        #expect(AppConfig.Source.envFileVariable("/p/x.env").description == "STOW_ENV_FILE (/p/x.env)")
        #expect(AppConfig.Source.configFile("/h/config.env").description == "config.env (/h/config.env)")
        #expect(AppConfig.Source.environment.description == "environment")
    }
}
