import CryptoKit
import Foundation
import GRDB
import Testing
@testable import StowStore

/// Shipped migrations are frozen (D-025): an archive that already ran `v3`
/// never runs it again, so editing `v3` would give new archives a different
/// schema from old ones without anyone noticing. This test records a hash of
/// the SQL each migration runs, and fails if any of them changes.
///
/// To add a migration: append its identifier and hash below (run the test
/// once; the failure message prints the hash). Never change an existing line.
/// If one fails, undo the edit to that migration and put the change in a new one.
@Suite struct FrozenMigrationTests {
    static let frozen: [(String, String)] = [
        ("v1", "bebbd4dd123e3e40e5a919e7e139f36a3c499832f758d1b73842db02abfa2dc8"),
        ("v2", "76999685347e1c4b2515531f6ddcb8ad3ceccb3c340a8cf0ecc9fa353a8acd74"),
        ("v3", "a73366183deaf8a34b13e81800fbc76fa987143781bb5b4eba3d5f663814369f"),
        ("v4", "6182408aeb83d6287422d81ed0a20d077bbf1bb69e8e7161b95c18e270d93f87"),
        ("v5", "12f78a0f6f030b7cc5173a5a3dc2ff5bc29882e4cdaceb991ad0a5f3017b399f"),
        ("v6", "73dc1f416094d80207577c1eb8f728cfb6b778f73b26f2ee9228cf2051732e28"),
        ("v7", "2de0626dfe25a36ab1452a42368f4305cd4214b5379f42e7f73f03ba6caf7c0b"),
    ]

    /// Runs each migration on an empty in-memory database, in order, and hashes
    /// the SQL statements it executes, one per line, as SQLite received them.
    static func hashes() throws -> [(String, String)] {
        let recorder = StatementRecorder()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in
                if case .statement(let statement) = event { recorder.add(statement.sql) }
            }
        }
        let queue = try DatabaseQueue(configuration: config)
        let steps: [(String, (Database) throws -> Void)] = [
            ("v1", ArchiveSchema.v1), ("v2", ArchiveSchema.v2), ("v3", ArchiveSchema.v3), ("v4", ArchiveSchema.v4),
            ("v5", ArchiveSchema.v5), ("v6", ArchiveSchema.v6), ("v7", ArchiveSchema.v7),
        ]
        var result: [(String, String)] = []
        for (identifier, migration) in steps {
            recorder.reset()
            try queue.inDatabase { db in try migration(db) }
            let text = recorder.statements.joined(separator: "\n")
            let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            result.append((identifier, digest))
        }
        return result
    }

    @Test func everyMigrationIsListed() {
        #expect(Self.frozen.map(\.0) == ArchiveSchema.migrationIdentifiers)
    }

    @Test func noShippedMigrationHasChanged() throws {
        let actual = try Self.hashes()
        #expect(actual.map(\.0) == Self.frozen.map(\.0))
        for ((identifier, expected), (_, digest)) in zip(Self.frozen, actual) {
            #expect(digest == expected, "Migration \(identifier) runs different SQL from the version that shipped (hash \(digest)). Shipped migrations are frozen (D-025): undo the change and add a new migration.")
        }
    }
}

private final class StatementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func add(_ sql: String) { lock.withLock { recorded.append(sql) } }
    func reset() { lock.withLock { recorded.removeAll() } }
    var statements: [String] { lock.withLock { recorded } }
}
