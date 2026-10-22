import CryptoKit
import Foundation
import GRDB
import Testing
@testable import StowStore

/// Proves the GRDB + SQLCipher setup (Phase 0, step 2; D-011): the file is
/// encrypted, reopens with the key, refuses without it, and FTS5 works.
@Suite struct SQLCipherTests {
    let directory: URL
    let url: URL
    let key: Data

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("archive.sqlite")
        key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    func createSampleDatabase() throws {
        let pool = try EncryptedDatabase.open(at: url, key: key)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE note (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE note_fts USING fts5(
                    body, tokenize = 'porter unicode61 remove_diacritics 2', prefix = '2 3')
                """)
            try db.execute(sql: "INSERT INTO note (id, body) VALUES (1, 'The quarterly invoices are attached')")
            try db.execute(sql: "INSERT INTO note_fts (rowid, body) VALUES (1, 'The quarterly invoices are attached')")
            try db.execute(sql: "INSERT INTO note (id, body) VALUES (2, 'Café menu for Friday')")
            try db.execute(sql: "INSERT INTO note_fts (rowid, body) VALUES (2, 'Café menu for Friday')")
        }
        try pool.close()
    }

    @Test func sqlcipherIsLinked() throws {
        let version = try #require(try EncryptedDatabase.cipherVersion())
        #expect(version.hasPrefix("4."))
    }

    @Test func reopensWithTheKeyAndSearchesWithFTS5() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSampleDatabase()

        let pool = try EncryptedDatabase.open(at: url, key: key)
        defer { try? pool.close() }
        let body = try pool.read { db in try String.fetchOne(db, sql: "SELECT body FROM note WHERE id = 1") }
        #expect(body == "The quarterly invoices are attached")

        func match(_ query: String) throws -> [Int] {
            try pool.read { db in try Int.fetchAll(db, sql: "SELECT rowid FROM note_fts WHERE note_fts MATCH ?", arguments: [query]) }
        }
        #expect(try match("invoice") == [1]) // Porter stemming: "invoice" matches "invoices".
        #expect(try match("quart*") == [1]) // Prefix query.
        #expect(try match("cafe") == [2]) // remove_diacritics: "cafe" matches "Café".

        let journalMode = try pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(journalMode == "wal")
    }

    @Test func refusesTheWrongKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSampleDatabase()
        let wrongKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        #expect(throws: DatabaseError.self) {
            _ = try EncryptedDatabase.open(at: url, key: wrongKey)
        }
    }

    @Test func refusesToOpenWithoutAKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSampleDatabase()
        #expect(throws: DatabaseError.self) {
            let queue = try DatabaseQueue(path: url.path)
            _ = try queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") }
        }
    }

    @Test func fileOnDiskIsNotPlainSQLite() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSampleDatabase()
        let bytes = try Data(contentsOf: url)
        #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
        #expect(bytes.range(of: Data("quarterly".utf8)) == nil)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if let data = try? Data(contentsOf: sidecar) {
                #expect(data.range(of: Data("quarterly".utf8)) == nil, "\(suffix) leaks plaintext")
            }
        }
    }

    @Test func systemSQLiteCannotReadIt() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSampleDatabase()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, "SELECT body FROM note"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus != 0)
        #expect(!text.contains("quarterly"))
    }

    @Test func rejectsKeysOfTheWrongLength() {
        #expect(throws: EncryptedDatabaseError.invalidKeyLength(16)) {
            _ = try EncryptedDatabase.open(at: url, key: Data(count: 16))
        }
    }
}
