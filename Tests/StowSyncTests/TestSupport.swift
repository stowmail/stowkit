import Foundation
import StowCore
import StowSecrets
@_exported import StowTestSupport
@testable import StowSync

/// Synthetic `.eml` fixtures made by scripts/make-fixtures (D-018).
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/eml", isDirectory: true)

    /// Every fixture, sorted by file name.
    static func all() throws -> [(name: String, bytes: Data)] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "eml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
    }

    /// Fixtures without the 15 MiB one, for tests that do not need it.
    static func small() throws -> [(name: String, bytes: Data)] {
        try all().filter { $0.bytes.count < 1_000_000 }
    }
}

/// A Keychain under a throwaway service name; callers delete it afterwards.
func makeTestKeychain() -> KeychainStore {
    KeychainStore(service: "uk.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
}

func temporaryDirectory(_ suffix: String = "") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("stow-sync-\(UUID().uuidString)\(suffix)", isDirectory: true)
}

/// Answers token requests from a script and records what was asked.
actor FakeTokenEndpoint: HTTPFormPosting {
    private(set) var requests: [[String: String]] = []
    private var responder: @Sendable ([String: String]) -> (Int, String)

    init(_ responder: @escaping @Sendable ([String: String]) -> (Int, String)) {
        self.responder = responder
    }

    func setResponder(_ responder: @escaping @Sendable ([String: String]) -> (Int, String)) {
        self.responder = responder
    }

    nonisolated func postForm(_ url: URL, fields: [(String, String)]) async throws -> (status: Int, body: Data) {
        await record(Dictionary(fields, uniquingKeysWith: { first, _ in first }))
    }

    private func record(_ fields: [String: String]) -> (status: Int, body: Data) {
        requests.append(fields)
        let (status, body) = responder(fields)
        return (status, Data(body.utf8))
    }
}

/// An unsigned JWT-shaped string with the given claims (tests never check signatures).
func fakeIDToken(_ claims: [String: Any]) -> String {
    let header = PKCE.base64URL(Data(#"{"alg":"none"}"#.utf8))
    let payload = PKCE.base64URL(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).sig"
}

let testAppConfig = try! AppConfig.load(
    environment: [
        "STOW_GOOGLE_CLIENT_ID": "test-client.apps.googleusercontent.com",
        "STOW_GOOGLE_CLIENT_SECRET": "test-secret-value",
        "STOW_MS_CLIENT_ID": "00000000-0000-0000-0000-000000000000",
        "STOW_MS_TENANT": "common",
    ],
    currentDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("stow-no-env-\(UUID().uuidString)")
)
