import CryptoKit
import Foundation
import GRDB
@testable import StowSecrets
import Testing
@testable import StowStore

/// D-486 (1), D-519: one wiped key buffer, and no key in SQL text.
@Suite(.serialized) struct KeyBufferTests {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    static func hex(_ key: Data) -> String { key.map { String(format: "%02x", $0) }.joined() }

    /// A database keyed exactly as v0.1.2 keyed it: `PRAGMA key` with the raw-key form.
    static func makeOldStyleDatabase(at url: URL, key: Data) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA key = \"x'\(hex(key))'\"") }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('kept')")
        }
        try queue.close()
    }

    @Test func aDatabaseKeyedByTheOldCodeOpensWithTheNewKeying() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stow-keybuffer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("archive.sqlite")
        let key = SymmetricKey(size: .bits256)
        try Self.makeOldStyleDatabase(at: url, key: key.withUnsafeBytes { Data($0) })

        let writer = try EncryptedDatabase.open(at: url, key: KeyBuffer(key))
        #expect(try writer.read { try String.fetchOne($0, sql: "SELECT v FROM t") } == "kept")
        try writer.write { try $0.execute(sql: "INSERT INTO t VALUES ('new')") }
        try writer.close()
        let reader = try EncryptedDatabase.open(at: url, key: KeyBuffer(key), readOnly: true)
        #expect(try reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM t") } == 2)
        try reader.close()

        #expect(throws: (any Error).self) { _ = try EncryptedDatabase.open(at: url, key: KeyBuffer(SymmetricKey(size: .bits256)), readOnly: true) }
    }

    @Test func theKeyNeverPassesThroughSQLText() throws {
        let key = SymmetricKey(size: .bits256)
        let hex = Self.hex(key.withUnsafeBytes { Data($0) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stow-keytrace-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = Seen()
        let buffer = KeyBuffer(key)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { seen.add($0.expandedDescription) }
            try EncryptedDatabase.applyKey(buffer, to: db)
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.write { try $0.execute(sql: "CREATE TABLE t (v)") }
        #expect(!seen.all.isEmpty)
        #expect(!seen.all.contains { $0.contains(hex) || $0.lowercased().contains("pragma key") })
    }

    @Test func aReleasedBufferIsZero() {
        let seen = Seen()
        KeyBuffer.releaseObserver = { bytes in seen.add(bytes.allSatisfy { $0 == 0 } ? "zero" : "NOT ZERO") }
        defer { KeyBuffer.releaseObserver = nil }
        do {
            let buffer = KeyBuffer(Data(repeating: 0xA5, count: 32))
            #expect(buffer.withUnsafeBytes { $0.allSatisfy { $0 == 0xA5 } })
            #expect(buffer.count == 32)
        }
        // Other suites may release buffers meanwhile; every release must be zero.
        #expect(!seen.all.isEmpty && !seen.all.contains("NOT ZERO"))
    }

    @Test func aWrongLengthIsRefused() {
        #expect(throws: EncryptedDatabaseError.invalidKeyLength(16)) {
            _ = try EncryptedDatabase.open(at: URL(fileURLWithPath: "/nonexistent/x.sqlite"), key: KeyBuffer(Data(count: 16)))
        }
    }
}
