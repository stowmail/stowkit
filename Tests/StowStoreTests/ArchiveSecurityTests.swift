import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

@Suite(.serialized) struct ArchiveSecurityTests {
    /// Imports the small fixtures (skips the 21 MB one to keep this quick).
    func importedArchive() throws -> TestArchive {
        let test = try TestArchive()
        let importer = Importer(archive: test.archive)
        for raw in try test.fixtureMessages() where raw.bytes.count < 1_000_000 {
            _ = try importer.importMessage(raw)
        }
        return test
    }

    @Test func databaseIsUnreadableWithoutTheKey() throws {
        let test = try importedArchive()
        defer { test.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [test.location.databaseURL.path, "SELECT count(*) FROM messages;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("not a database"))

        // And with the wrong key.
        #expect(throws: (any Error).self) {
            _ = try Archive.open(test.location, keys: TestArchive.randomKeys(), readOnly: true)
                .database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") }
        }
    }

    @Test func filesRevealNothing() throws {
        let test = try importedArchive()
        defer { test.remove() }
        let files = test.files(in: test.location.rawDirectory) + test.files(in: test.location.attachmentsDirectory)
        #expect(files.count > 20)
        let keywords = ["LANTERN-COAST-1150", "PERIWINKLE", "%PDF", "Return-Path", "PNG", "word/document.xml", "example.org"]
        for file in files {
            #expect(file.lastPathComponent.count == 64)
            #expect(file.lastPathComponent.allSatisfy { $0.isHexDigit })
            let data = try Data(contentsOf: file)
            #expect(data.prefix(4) == Data("STOW".utf8))
            for keyword in keywords {
                #expect(data.range(of: Data(keyword.utf8)) == nil, "\(keyword) visible in \(file.lastPathComponent)")
            }
        }
    }

    @Test func fileNamesAreKeyedNotPlainHashes() throws {
        let one = try TestArchive()
        let two = try TestArchive()
        defer { one.remove(); two.remove() }
        let content = Data("same content".utf8)
        #expect(one.archive.attachmentFiles.hash(of: content) != two.archive.attachmentFiles.hash(of: content))
    }

    @Test func filesFailToOpenWithTheWrongKeyOrUnderAnotherName() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = test.archive.attachmentFiles
        let first = Data("first".utf8), second = Data("second".utf8)
        let firstHash = store.hash(of: first), secondHash = store.hash(of: second)
        try store.write(first, hash: firstHash)
        try store.write(second, hash: secondHash)
        #expect(try store.read(firstHash) == first)

        let other = EncryptedFileStore(directory: store.directory, kind: .attachment, keys: TestArchive.randomKeys())
        #expect(throws: EncryptedFileError.authenticationFailed) { try other.read(firstHash) }

        // Swap the two files on disk: each must now fail rather than return the other's content.
        let a = store.url(for: firstHash), b = store.url(for: secondHash)
        let temporary = a.appendingPathExtension("swap")
        try FileManager.default.moveItem(at: a, to: temporary)
        try FileManager.default.moveItem(at: b, to: a)
        #expect(throws: EncryptedFileError.authenticationFailed) { try store.read(firstHash) }
    }

    @Test func permissionsAreOwnerOnly() throws {
        let test = try importedArchive()
        defer { test.remove() }
        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(try mode(test.location.root) == 0o700)
        let enumerator = FileManager.default.enumerator(at: test.location.root, includingPropertiesForKeys: nil)
        for case let url as URL in enumerator! {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            #expect(try mode(url) == (isDirectory ? 0o700 : 0o600), "\(url.lastPathComponent)")
        }
    }

    @Test func cloudSyncedLocationsAreRefused() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in ["Library/Mobile Documents/com~apple~CloudDocs/Stow", "Library/CloudStorage/Dropbox/Stow"] {
            #expect(throws: (any Error).self) {
                try ArchiveLocation.refuseCloudSynced(home.appendingPathComponent(path))
            }
        }
        #expect(throws: Never.self) {
            try ArchiveLocation.refuseCloudSynced(FileManager.default.temporaryDirectory.appendingPathComponent("stow"))
        }
    }

    @Test func noMessageContentInLogs() throws {
        // The store logs through swift-log only with keys, counts and scrubbed errors.
        // Scan the sources for logging calls that interpolate anything else.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let allowed = ["\"\\(key)\"", "Redact.", "\"\\(summary)\"", "\"\\(count)\"", "\"\\(id)\"", "\"\\(attachmentID)\""]
        for module in ["StowStore", "StowSearch"] {
            let enumerator = FileManager.default.enumerator(at: sources.appendingPathComponent(module), includingPropertiesForKeys: nil)
            for case let url as URL in enumerator! where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n") where line.contains("logger.") {
                    guard line.contains("\\(") else { continue }
                    #expect(allowed.contains { line.contains($0) }, "\(url.lastPathComponent): \(line)")
                }
            }
        }
    }
}

@Suite struct MigrationTests {
    /// For every migration: build a database at the previous version, add rows,
    /// copy the file, migrate the copy, and check integrity and foreign keys.
    @Test func everyMigrationRunsOnACopyOfThePreviousVersion() throws {
        let keys = TestArchive.randomKeys()
        let identifiers = ArchiveSchema.migrationIdentifiers
        for (index, identifier) in identifiers.enumerated() {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stow-migrate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let original = folder.appendingPathComponent("previous.sqlite")
            do {
                let db = try EncryptedDatabase.open(at: original, key: keys.databaseKeyData)
                if index > 0 {
                    try ArchiveSchema.migrator.migrate(db, upTo: identifiers[index - 1])
                    try SampleRows.insert(db, atVersion: identifiers[index - 1])
                }
                try db.close()
            }
            let copy = folder.appendingPathComponent("copy.sqlite")
            try FileManager.default.copyItem(at: original, to: copy)
            let db = try EncryptedDatabase.open(at: copy, key: keys.databaseKeyData)
            try ArchiveSchema.migrator.migrate(db, upTo: identifier)
            let (integrity, foreignKeyProblems, applied) = try db.read { db in
                (try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                 try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
                 try ArchiveSchema.migrator.appliedIdentifiers(db))
            }
            #expect(integrity == "ok")
            #expect(foreignKeyProblems == 0)
            #expect(applied.contains(identifier))
            try SampleRows.insert(db, atVersion: identifier)
            try db.close()
        }
    }

    @Test func migratingTwiceIsHarmless() throws {
        let test = try TestArchive()
        defer { test.remove() }
        try ArchiveSchema.migrate(test.archive.database)
        let again = try Archive.open(test.location, keys: test.keys)
        #expect(try again.database.read { db in try ArchiveSchema.migrator.hasCompletedMigrations(db) })
    }

    @Test func schemaUsesStrictTables() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let sql = try test.archive.database.read { db in
            try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'messages_fts%' AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%'")
        }
        #expect(sql.count == 12)
        for statement in sql { #expect(statement.hasSuffix("STRICT"), "\(statement.prefix(40))") }
    }
}

/// Representative rows for each schema version, so each migration is tested on data, not an empty file.
enum SampleRows {
    static func insert(_ db: DatabasePool, atVersion version: String) throws {
        try db.write { db in
            switch version {
            case "v1":
                let account = UUID().uuidString.lowercased()
                try db.execute(sql: "INSERT INTO accounts (id, provider, email, display_name, created_at) VALUES (?, 'gmail', ?, 'T', 0)",
                               arguments: [account, "\(account)@example.com"])
                try db.execute(sql: "INSERT INTO addresses (address, domain) VALUES (?, 'example.com') ON CONFLICT DO NOTHING",
                               arguments: ["a-\(account)@example.com"])
                try db.execute(sql: """
                    INSERT INTO messages (account_id, raw_hash, internal_date, size, raw_stored_size, parse_status, parser_version, imported_at)
                    VALUES (?, randomblob(32), 0, 1, 1, 'ok', 1, 0)
                    """, arguments: [account])
                try db.execute(sql: "INSERT INTO messages_fts (rowid, subject) VALUES (?, 'sample')", arguments: [db.lastInsertedRowID])
            default:
                Issue.record("Add sample rows for migration \(version)")
            }
        }
    }
}
