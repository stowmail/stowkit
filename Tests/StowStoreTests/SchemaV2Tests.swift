import CryptoKit
import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Migration v2 (D-481, D-501): the "couldn't read all of this email" mark and
/// the attempt counts, added to archives that already hold real mail.
@Suite(.serialized) struct SchemaV2Tests {
    @Test func freshArchiveImportsWithCompleteTextAndNoAttempts() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        #expect(try test.count("messages") == 25)
        #expect(try test.count("messages", "text_state = 'complete' AND text_marked_version IS NULL AND text_attempts = 0") == 25)
        #expect(try test.count("attachments") > 0)
        #expect(try test.count("attachments", "text_attempts = 0 AND text_last_attempt_at IS NULL AND text_failed_version IS NULL")
                == test.count("attachments"))
        let applied = try await test.archive.database.read { db in try ArchiveSchema.migrator.appliedIdentifiers(db) }
        #expect(applied == Set(ArchiveSchema.migrationIdentifiers))
    }

    @Test func markAndVersionAreSetTogether() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        let refused = [
            "UPDATE messages SET text_state = 'incomplete' WHERE id = 1",                          // no version
            "UPDATE messages SET text_marked_version = 1 WHERE id = 1",                            // version on complete text
            "UPDATE messages SET text_state = 'partial', text_marked_version = 1 WHERE id = 1",    // not a state
        ]
        for sql in refused {
            await #expect(throws: DatabaseError.self, "\(sql)") { try await test.archive.database.write { db in try db.execute(sql: sql) } }
        }
        try await test.archive.database.write { db in
            try db.execute(sql: "UPDATE messages SET text_state = 'incomplete', text_marked_version = ? WHERE id = 1",
                           arguments: [MIMEParser.version])
            try db.execute(sql: "UPDATE messages SET text_state = 'complete', text_marked_version = NULL WHERE id = 1")
        }
    }

    /// The upgrade on a copy of an archive the size of a real one: built at v1,
    /// copied, and the copy migrated. Every v1 value must read back unchanged,
    /// every row must say its text is complete with nothing attempted, and the
    /// database, foreign keys and search index must check clean.
    ///
    /// 2,000 messages by default, so every `check.sh` and CI run covers it. For
    /// the full size (D-501 records the measured run), in a release build:
    ///
    ///     STOW_MIGRATION_MESSAGES=40000 swift test -c release -Xswiftc -enable-testing --filter SchemaV2Tests
    @Test func upgradeFromV1OnACopyOfARealSizedArchive() throws {
        let messages = Int(ProcessInfo.processInfo.environment["STOW_MIGRATION_MESSAGES"] ?? "") ?? 2_000
        let keys = TestArchive.randomKeys()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stow-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = folder.appendingPathComponent("v1.sqlite")
        let built = Date()
        let before: [String: Data]
        let rows: [String: Int]
        do {
            let db = try EncryptedDatabase.open(at: original, key: keys.databaseKeyData)
            try ArchiveSchema.migrator.migrate(db, upTo: "v1")
            try RealSizedArchive.fill(db, messages: messages)
            (before, rows) = try db.read { db in (try V1Snapshot.digests(db), try V1Snapshot.rowCounts(db)) }
            try db.close()
        }
        let buildSeconds = Date().timeIntervalSince(built)

        let copy = folder.appendingPathComponent("copy.sqlite")
        try FileManager.default.copyItem(at: original, to: copy)
        let fileSize = try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int ?? 0
        let db = try EncryptedDatabase.open(at: copy, key: keys.databaseKeyData)
        let started = Date()
        try ArchiveSchema.migrator.migrate(db, upTo: "v2")
        let migrateSeconds = Date().timeIntervalSince(started)

        let after = try db.read { db -> AfterUpgrade in
            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql)! }
            return AfterUpgrade(
                applied: try ArchiveSchema.migrator.appliedIdentifiers(db),
                integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                foreignKeyProblems: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
                digests: try V1Snapshot.digests(db),
                rows: try V1Snapshot.rowCounts(db),
                marked: try count("SELECT count(*) FROM messages WHERE text_state != 'complete' OR text_marked_version IS NOT NULL OR text_attempts != 0"),
                queueAttempts: try count("SELECT count(*) FROM download_queue WHERE import_attempts != 0 OR last_import_attempt_at IS NOT NULL"),
                attachmentAttempts: try count("SELECT count(*) FROM attachments WHERE text_attempts != 0 OR text_last_attempt_at IS NOT NULL OR text_failed_version IS NOT NULL"))
        }
        let searchIndexAgrees = try db.write { db in try SearchIndexWriter.integrityCheck(db) }   // FTS5 runs its check as a write
        let plans = try db.read { db in try RetryQueries.plans(db) }
        #expect(after.applied == ["v1", "v2"])
        #expect(after.integrity == "ok")
        #expect(after.foreignKeyProblems == 0)
        #expect(searchIndexAgrees)
        RetryQueries.expectIndexed(plans)
        #expect(after.digests == before)
        #expect(after.rows == rows)
        #expect(rows["messages"] == messages && rows["messages_fts"] == messages)
        #expect(rows["download_queue", default: 0] > 0 && rows["attachments", default: 0] > 0)
        #expect(after.marked == 0)
        #expect(after.queueAttempts == 0)
        #expect(after.attachmentAttempts == 0)
        // Mail imported after the upgrade by v2 code, and by an older build that knows only v1 columns.
        try SampleRows.insert(db, atVersion: "v1")
        try SampleRows.insert(db, atVersion: "v2")
        try db.close()
        print("v2 upgrade: \(messages) messages, \(fileSize / 1_000_000) MB database (built in \(Int(buildSeconds)) s), migrated in \(String(format: "%.3f", migrateSeconds)) s")
    }

    /// The retry queries step 7 runs, and the "couldn't read" counts for `status`,
    /// read through v2's partial indexes. The engine never runs ANALYZE, so these
    /// are the plans a real archive gets too; the upgrade test checks them again
    /// on the real-sized copy.
    @Test func retryQueriesUseThePartialIndexes() throws {
        let test = try TestArchive()
        defer { test.remove() }
        RetryQueries.expectIndexed(try test.archive.database.read { db in try RetryQueries.plans(db) })
    }
}

/// The queries D-501 gives step 7, each with the index it must use.
enum RetryQueries {
    static let expected: [(sql: String, index: String)] = [
        ("SELECT id FROM messages WHERE text_state = 'incomplete' AND text_marked_version < 2",
         "USING COVERING INDEX messages_text_incomplete (text_marked_version<?)"),
        ("SELECT count(*) FROM messages WHERE text_state = 'incomplete'",
         "USING COVERING INDEX messages_text_incomplete"),
        ("SELECT id FROM attachments WHERE text_status = 'unsupported' AND text_failed_version < 2",
         "USING COVERING INDEX attachments_text_failed (text_status=? AND text_failed_version<?)"),
        ("SELECT id FROM attachments WHERE text_status = 'ocr_failed' AND text_failed_version < 2",
         "USING COVERING INDEX attachments_text_failed (text_status=? AND text_failed_version<?)"),
        ("SELECT count(DISTINCT message_id) FROM message_attachments WHERE attachment_id IN (SELECT id FROM attachments WHERE text_failed_version IS NOT NULL)",
         "USING COVERING INDEX attachments_text_failed"),
    ]

    static func plans(_ db: Database) throws -> [String] {
        try expected.map { query in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)").map { $0["detail"] as String }.joined(separator: "; ")
        }
    }

    static func expectIndexed(_ plans: [String]) {
        for (query, plan) in zip(expected, plans) {
            #expect(plan.contains(query.index), "\(query.sql): \(plan)")
            // Scanning a partial index reads only marked rows; scanning a table reads every row.
            let tableScans = plan.components(separatedBy: "; ").filter { $0.hasPrefix("SCAN ") && !$0.contains(" INDEX ") }
            #expect(tableScans.isEmpty, "\(query.sql): \(plan)")
        }
    }
}

struct AfterUpgrade {
    let applied: Set<String>
    let integrity: String?
    let foreignKeyProblems: Int
    let digests: [String: Data]
    let rows: [String: Int]
    let marked: Int
    let queueAttempts: Int
    let attachmentAttempts: Int
}

/// A digest of every v1 column of every table, so the upgrade can be shown to change no existing value.
enum V1Snapshot {
    static let tables = ["accounts", "folders", "addresses", "messages", "message_bodies", "message_folders",
                         "message_addresses", "attachments", "message_attachments", "attachment_text", "sync_state",
                         "download_queue", "byte_budget", "sync_events", "tombstones", "tombstone_copies",
                         "archive_meta", "rule_overrides"]
    static let addedInV2: Set<String> = ["text_state", "text_marked_version", "text_attempts", "import_attempts",
                                         "last_import_attempt_at", "text_last_attempt_at", "text_failed_version"]

    /// `excluding` names the columns a later migration added; v3's upgrade test leaves out only its own.
    static func digests(_ db: Database, excluding: Set<String> = addedInV2) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for table in tables {
            let columns = try db.columns(in: table).map(\.name).filter { !excluding.contains($0) }
            var hash = SHA256()
            let cursor = try Row.fetchCursor(db, sql: "SELECT \(columns.joined(separator: ", ")) FROM \(table) ORDER BY rowid")
            while let row = try cursor.next() { hash.update(data: Data(row.description.utf8)) }
            result[table] = Data(hash.finalize())
        }
        return result
    }

    static func rowCounts(_ db: Database) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for table in tables + ["messages_fts"] { result[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")! }
        return result
    }
}

/// A synthetic v1 archive shaped like a real one: two accounts (Gmail labels and
/// Microsoft folders), every message with a body, addresses and folder places,
/// one in eight with attachments (some shared, some with text, some waiting for
/// OCR or unsupported), and a download queue with fetch failures and
/// unfetchable rows. All text is made-up words from a fixed seed.
enum RealSizedArchive {
    static func fill(_ db: DatabasePool, messages count: Int) throws {
        var random = SplitMix(seed: 0x5EED_0002)
        try db.write { db in
            let accounts = ["00000000-0000-4000-8000-0000000000a1", "00000000-0000-4000-8000-0000000000a2"]
            try db.execute(sql: "INSERT INTO accounts (id, provider, email, display_name, created_at) VALUES (?, 'gmail', 'sam@example.com', 'Sam', 0), (?, 'microsoft', 'sam@example.org', 'Work', 0)",
                           arguments: [accounts[0], accounts[1]])
            let folderNames = [(0, "[Gmail]/All Mail", "folder", "\\all"), (0, "INBOX", "label", nil), (0, "Receipts", "label", nil),
                               (1, "INBOX", "folder", nil), (1, "Sent Items", "folder", "\\sent"), (1, "Archive", "folder", nil)]
            for (account, name, kind, special) in folderNames {
                try db.execute(sql: "INSERT INTO folders (account_id, name, kind, special_use, uid_validity) VALUES (?, ?, ?, ?, ?)",
                               arguments: [accounts[account], name, kind, special, kind == "folder" ? 7 : nil])
            }
            for folder in [1, 4, 5, 6] {
                try db.execute(sql: "INSERT INTO sync_state (folder_id, uid_validity, listed_through_uid, status) VALUES (?, 7, ?, 'idle')",
                               arguments: [folder, count])
            }

            let addressCount = max(50, count / 20)
            let insertAddress = try db.makeStatement(sql: "INSERT INTO addresses (address, domain) VALUES (?, ?)")
            for index in 0..<addressCount {
                let domain = "\(random.word())\(index % 97).example"
                try insertAddress.execute(arguments: ["\(random.word()).\(index)@\(domain)", domain])
            }

            let insertMessage = try db.makeStatement(sql: """
                INSERT INTO messages (account_id, raw_hash, rfc822_message_id, gmail_msgid, gmail_thrid, thread_key, internal_date,
                    sent_date, date_raw, subject, from_address_id, size, has_attachments, raw_state, raw_stored_size,
                    raw_inline_attachments, parse_status, parse_warnings, parser_version, source_state, source_state_at,
                    rule_suggestion, rule_score, rule_signals, imported_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 1, ?, ?, ?, ?, ?, ?)
                """)
            let insertBody = try db.makeStatement(sql: "INSERT INTO message_bodies (message_id, text_plain, text_from_html) VALUES (?, ?, ?)")
            let insertPlace = try db.makeStatement(sql: "INSERT INTO message_folders (message_id, folder_id, uid_validity, uid, flags, last_seen_at, removed_from_server_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
            let insertAddressRole = try db.makeStatement(sql: "INSERT INTO message_addresses (message_id, role, position, address_id, display_name) VALUES (?, ?, ?, ?, ?)")
            let insertAttachment = try db.makeStatement(sql: "INSERT INTO attachments (content_hash, size, stored_size, mime_type, text_status, created_at) VALUES (?, ?, ?, ?, ?, ?)")
            let insertPart = try db.makeStatement(sql: "INSERT INTO message_attachments (message_id, part_path, attachment_id, filename, declared_mime_type, disposition) VALUES (?, ?, ?, ?, ?, ?)")
            let insertText = try db.makeStatement(sql: "INSERT INTO attachment_text (attachment_id, text, method, extractor_version, extracted_at) VALUES (?, ?, ?, 1, ?)")

            let statuses = ["extracted", "extracted", "extracted", "ocr_pending", "ocr_done", "ocr_failed", "unsupported", "none"]
            var attachmentIDs: [Int64] = []
            for index in 0..<count {
                let gmail = index % 3 != 0
                let account = accounts[gmail ? 0 : 1]
                let date = 1_500_000_000 + index * 2_400
                let hasAttachments = index % 8 == 0
                let parse = index % 50 == 0 ? "degraded" : (index % 997 == 0 ? "failed" : "ok")
                let source = ["present", "present", "present", "present", "spam", "trashed", "gone"][Int(random.next() % 7)]
                try insertMessage.execute(arguments: [
                    account, random.bytes(32), "\(index).\(random.word())@mail.example", gmail ? index + 1 : nil, gmail ? index / 4 + 1 : nil,
                    gmail ? "g:\(index / 4 + 1)" : "m:\(index / 4)@mail.example", date, date - 30, "Mon, 1 Jan 2018 00:00:00 +0000",
                    random.sentence(words: 4 + Int(random.next() % 8)), Int(random.next() % UInt64(addressCount)) + 1,
                    2_000 + Int(random.next() % 60_000), hasAttachments ? 1 : 0, hasAttachments ? "skeleton" : "full", 1_500 + Int(random.next() % 20_000),
                    parse, parse == "ok" ? nil : "[\"malformed Date\"]", source, source == "present" ? nil : date + 86_400,
                    ["keep", "deprioritise", "consider_deleting", nil][Int(random.next() % 4)], Int(random.next() % 10), "list-unsubscribe",
                    date + 60,
                ])
                let id = db.lastInsertedRowID
                let body = random.sentence(words: 300 + Int(random.next() % 1_200))
                try insertBody.execute(arguments: [id, index % 5 == 0 ? nil : body, index % 5 == 0 ? body : nil])
                if gmail {
                    try insertPlace.execute(arguments: [id, 1, 7, index + 1, "\\Seen", date, nil])
                    try insertPlace.execute(arguments: [id, index % 2 == 0 ? 2 : 3, nil, nil, nil, date, nil])
                } else {
                    try insertPlace.execute(arguments: [id, [4, 5, 6][index % 3], 7, index + 1, "\\Seen", date, index % 40 == 0 ? date + 9_000 : nil])
                }
                let roles = [("from", 1), ("to", 1 + Int(random.next() % 3)), ("cc", Int(random.next() % 3)), ("reply_to", Int(random.next() % 2))]
                for (role, total) in roles {
                    for position in 0..<total {
                        try insertAddressRole.execute(arguments: [id, role, position, Int(random.next() % UInt64(addressCount)) + 1,
                                                                  random.next() % 2 == 0 ? nil : random.sentence(words: 2)])
                    }
                }
                if hasAttachments {
                    for part in 0..<(1 + Int(random.next() % 3)) {
                        let attachment: Int64
                        if !attachmentIDs.isEmpty && random.next() % 4 == 0 {
                            attachment = attachmentIDs[Int(random.next() % UInt64(attachmentIDs.count))]   // the same file sent again
                        } else {
                            let status = statuses[Int(random.next() % UInt64(statuses.count))]
                            let size = 10_000 + Int(random.next() % 2_000_000)
                            try insertAttachment.execute(arguments: [random.bytes(32), size, size + 28, "application/pdf", status, date])
                            attachment = db.lastInsertedRowID
                            attachmentIDs.append(attachment)
                            if status == "extracted" || status == "ocr_done" {
                                try insertText.execute(arguments: [attachment, random.sentence(words: 200 + Int(random.next() % 2_000)),
                                                                   status == "ocr_done" ? "ocr" : "pdfkit", date])
                            }
                        }
                        try insertPart.execute(arguments: [id, "\(part + 2)", attachment, "\(random.word())-\(part).pdf", "application/pdf",
                                                           part == 0 ? "attachment" : "inline"])
                    }
                }
            }

            let insertQueued = try db.makeStatement(sql: """
                INSERT INTO download_queue (folder_id, uid_validity, uid, size, internal_date, priority, gmail_msgid, state, restore,
                    attempts, last_run_id, first_failed_at, last_failed_at, flags, recorded_at, queued_at)
                VALUES (?, 7, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)
                """)
            for index in 0..<max(20, count / 50) {
                let uid = count + 1 + index
                let failed = index % 10 == 0
                let unfetchable = index % 40 == 0
                try insertQueued.execute(arguments: [
                    index % 2 == 0 ? 1 : 4, uid, 5_000 + index, 1_700_000_000 + index, index % 3, index % 2 == 0 ? uid : nil,
                    unfetchable ? "unfetchable" : "queued", unfetchable ? 3 : (failed ? 1 : 0), failed || unfetchable ? "run-\(index)" : nil,
                    failed || unfetchable ? 1_700_000_100 : nil, failed || unfetchable ? 1_700_000_200 : nil, "\\Seen",
                    unfetchable ? 1_700_000_300 : nil, 1_700_000_000,
                ])
            }
            try db.execute(sql: "INSERT INTO sync_events (account_id, folder_id, kind, old_value, new_value, at) VALUES (?, 4, 'uidvalidity_changed', '6', '7', 1)",
                           arguments: [accounts[1]])
            try db.execute(sql: "INSERT INTO byte_budget (account_id, at, bytes) VALUES (?, 1, 1000000)", arguments: [accounts[0]])
            try db.execute(sql: "INSERT INTO tombstones (account_id, raw_hash, internal_date, size, sender, reason, removed_at) VALUES (?, randomblob(32), 1, 100, 'shop.example', 'sender:shop.example', 2)",
                           arguments: [accounts[0]])
            try db.execute(sql: "INSERT INTO tombstone_copies (tombstone_id, folder_id, uid_validity, uid) VALUES (1, 1, 7, ?)", arguments: [count + 100_000])
            try db.execute(sql: "INSERT INTO rule_overrides (account_id, match, suggestion, created_at) VALUES (NULL, 'shop.example', 'deprioritise', 1)")
            try db.execute(sql: "INSERT INTO archive_meta (key, value) VALUES ('archive_id', 'synthetic'), ('created_at', '0')")
            try SearchIndexWriter.rebuild(db)
        }
    }
}

/// A small, fast, seeded generator, so the synthetic archive is the same on every run.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static let syllables = ["ka", "lo", "mi", "ren", "sa", "tu", "vel", "dor", "pe", "qua", "ix", "bo", "ne", "sti", "ar", "gu"]

    mutating func word() -> String {
        (0..<(1 + Int(next() % 3))).map { _ in Self.syllables[Int(next() % UInt64(Self.syllables.count))] }.joined()
    }

    mutating func sentence(words: Int) -> String {
        (0..<words).map { _ in word() }.joined(separator: " ")
    }

    mutating func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) })
    }
}
