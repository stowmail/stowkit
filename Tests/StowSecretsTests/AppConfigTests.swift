import Foundation
import Testing
@testable import StowSecrets

/// Uses fake values only. Never reads the real engine/.env.
@Suite struct AppConfigTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func writeEnv(_ text: String) throws {
        try text.write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
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
        let config = try AppConfig.load(environment: [:], currentDirectory: directory)
        #expect(config.googleClientID == "fake-google-id.apps.googleusercontent.com")
        #expect(config.googleClientSecret == "fake-google-secret")
        #expect(config.microsoftClientID == "fake-ms-id")
        #expect(config.microsoftTenant == "common")
    }

    @Test func environmentWinsOverFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv(complete)
        let config = try AppConfig.load(environment: ["STOW_MS_TENANT": "organizations"], currentDirectory: directory)
        #expect(config.microsoftTenant == "organizations")
    }

    @Test func envFileVariableOverridesLocation() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = directory.appendingPathComponent("custom.env")
        try complete.write(to: other, atomically: true, encoding: .utf8)
        let config = try AppConfig.load(environment: ["STOW_ENV_FILE": other.path], currentDirectory: URL(fileURLWithPath: "/nonexistent"))
        #expect(config.microsoftClientID == "fake-ms-id")

        #expect(throws: AppConfigError.unreadableFile("missing.env")) {
            try AppConfig.load(environment: ["STOW_ENV_FILE": directory.appendingPathComponent("missing.env").path])
        }
    }

    @Test func worksFromEnvironmentAlone() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "STOW_GOOGLE_CLIENT_ID": "g", "STOW_GOOGLE_CLIENT_SECRET": "s",
            "STOW_MS_CLIENT_ID": "m", "STOW_MS_TENANT": "common",
        ]
        #expect(try AppConfig.load(environment: environment, currentDirectory: directory).googleClientID == "g")
    }

    @Test func missingKeyNamesTheKeyOnly() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv(complete.replacingOccurrences(of: "STOW_MS_CLIENT_ID='fake-ms-id'", with: ""))
        #expect(throws: AppConfigError.missing("STOW_MS_CLIENT_ID")) {
            try AppConfig.load(environment: [:], currentDirectory: directory)
        }
    }

    @Test func placeholderIsRejectedWithoutShowingTheValue() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv(complete.replacingOccurrences(of: "fake-google-id", with: "REPLACE_ME"))
        do {
            _ = try AppConfig.load(environment: [:], currentDirectory: directory)
            Issue.record("expected an error")
        } catch let error as AppConfigError {
            #expect(error == .placeholder("STOW_GOOGLE_CLIENT_ID"))
            #expect(!error.description.contains("googleusercontent"))
        }
    }

    @Test func errorsNeverContainValues() {
        for error in [AppConfigError.missing("K"), .placeholder("K"), .unreadableFile(".env")] {
            #expect(!error.description.contains("fake"))
        }
    }

    @Test func reportShowsStatusNotValues() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEnv("STOW_GOOGLE_CLIENT_ID=REPLACE_ME.apps.googleusercontent.com\nSTOW_MS_TENANT=common\n")
        let report = try AppConfig.report(environment: [:], currentDirectory: directory)
        let statuses = Dictionary(uniqueKeysWithValues: report.map { ($0.key, $0.status) })
        #expect(statuses["STOW_GOOGLE_CLIENT_ID"] == .placeholder)
        #expect(statuses["STOW_GOOGLE_CLIENT_SECRET"] == .missing)
        #expect(statuses["STOW_MS_TENANT"] == .set)
    }

    @Test func matchesTheCommittedExampleKeys() throws {
        // engine/.env.example is safe to read: it holds placeholders only.
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".env.example")
        let keys = Set(AppConfig.parseEnvFile(try String(contentsOf: example, encoding: .utf8)).keys)
        #expect(keys == Set(AppConfig.Key.allCases.map(\.rawValue)))
    }
}
