import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Phase 2 step 2 (D-005, D-029, D-030, D-042): skeletons at ingest, the
/// external-content search index, `verify` and mbox export.
@Suite(.serialized) struct SkeletonStorageTests {
    @Test func everyFixtureRebuildsByteForByte() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let messages = try test.fixtureMessages()
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(messages))
        let rows = try await test.archive.database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, raw_hash, raw_state FROM messages ORDER BY id")
                .map { ($0["id"] as Int64, $0["raw_hash"] as Data, $0["raw_state"] as String) }
        }
        #expect(rows.count == messages.count)
        for (row, message) in zip(rows, messages) {
            #expect(try test.archive.rawMessage(row.0) == message.bytes)
            // The file's skeleton flag agrees with the database.
            let file = try test.archive.rawFiles.readFile(row.1)
            #expect(file.isSkeleton == (row.2 == "skeleton"))
        }
        // Every fixture with an attachment body of 64 bytes or more is a skeleton: 04 to 09 and 24.
        #expect(try test.count("messages", "raw_state = 'skeleton'") == 7)
        #expect(try test.count("messages", "raw_inline_attachments > 0") == 0)
    }

    @Test func theLargeAttachmentIsStoredOnceNotTwice() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let data = try Fixtures.data("05-")
        _ = try Importer(archive: test.archive).importMessage(test.raw(data, uid: 1))
        let messageFiles = test.files(in: test.location.rawDirectory).reduce(0) { $0 + (EncryptedFileStore.fileSize($1) ?? 0) }
        let attachmentFiles = test.files(in: test.location.attachmentsDirectory).reduce(0) { $0 + (EncryptedFileStore.fileSize($1) ?? 0) }
        #expect(messageFiles < 4096) // the skeleton
        #expect(attachmentFiles > 15_000_000) // the decoded attachment, once
        #expect(messageFiles + attachmentFiles < data.count) // base64's third is gone
    }

    /// The brief: broken base64 takes the inline fallback where needed.
    @Test func brokenBase64StaysInlineAndStillRebuilds() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let line = String(repeating: "QUJD", count: 19)
        let broken = "\(line)\r\nQUJ!#\(line)\r\n\(line.prefix(20))\r\n"
        let raw = Data("""
            From: a@example.com\r\nTo: sam@example.com\r\nSubject: broken\r\nMessage-ID: <broken@example.com>\r
            MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="b"\r\n\r\n--b\r\nContent-Type: text/plain\r\n\r\nhello\r\n--b\r
            Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=x.bin\r
            \r\n\(broken)--b--\r\n
            """.utf8)
        guard case .imported(let id) = try Importer(archive: test.archive).importMessage(test.raw(raw, uid: 1)) else {
            Issue.record("should import")
            return
        }
        #expect(try test.count("messages", "raw_state = 'full' AND raw_inline_attachments = 1") == 1)
        #expect(try test.archive.rawMessage(id) == raw)
        #expect(try test.count("attachments") == 1) // still decoded and searchable by name
    }

    /// The brief: a nested message/rfc822 with a real attachment inside is cut where
    /// it can be, and rebuilds exactly.
    @Test func nestedForwardedMessageAttachmentIsCutAndRebuilds() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let payload = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 * 7) }).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let raw = Data("""
            From: a@example.com\r\nTo: sam@example.com\r\nSubject: Fwd\r\nMessage-ID: <fwd@example.com>\r\nMIME-Version: 1.0\r
            Content-Type: multipart/mixed; boundary="outer"\r\n\r\n--outer\r\nContent-Type: text/plain\r\n\r\nSee below.\r\n--outer\r
            Content-Type: message/rfc822\r\n\r\nFrom: b@example.org\r\nSubject: Inner\r\nMIME-Version: 1.0\r
            Content-Type: multipart/mixed; boundary="inner"\r\n\r\n--inner\r\nContent-Type: text/plain\r\n\r\nInner text.\r\n--inner\r
            Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=inner.bin\r
            \r\n\(payload)\r\n--inner--\r\n--outer--\r\n
            """.utf8)
        guard case .imported(let id) = try Importer(archive: test.archive).importMessage(test.raw(raw, uid: 1)) else {
            Issue.record("should import")
            return
        }
        #expect(try test.count("messages", "raw_state = 'skeleton'") == 1)
        #expect(try test.archive.rawMessage(id) == raw)
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
    }

    @Test func dedupStillWorksWithSkeletonsAcrossAccounts() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let other = Account(id: AccountID(rawValue: "00000000-0000-4000-8000-000000000002"), provider: .gmail,
                            email: "sam@example.org", displayName: "Other")
        try test.archive.register(other)
        let importer = Importer(archive: test.archive)
        let pdf = try Fixtures.data("06-")
        _ = try importer.importMessage(test.raw(pdf, uid: 1))
        _ = try importer.importMessage(test.raw(try Fixtures.data("07-"), uid: 2))
        let otherRaw = RawMessage(key: RawMessageKey(accountID: other.id, folder: "[Gmail]/All Mail", uidValidity: 1, uid: 1),
                                  internalDate: Date(), size: pdf.count, bytes: pdf)
        _ = try importer.importMessage(otherRaw)
        #expect(try test.count("messages") == 3)
        #expect(try test.count("attachments") == 1)
        // Identical bytes in two accounts share one message file.
        #expect(test.files(in: test.location.rawDirectory).count == 2)
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
    }

    @Test func searchIndexHoldsNoCopyOfTheTextAndStaysConsistent() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages()))
        let tables = try await test.archive.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'messages_fts%'")
        }
        #expect(!tables.contains("messages_fts_content")) // a view, not a table: no second copy of the bodies
        #expect(try await test.archive.database.write { db in try SearchIndexWriter.integrityCheck(db) })

        // OCR changes an attachment's text: the index follows, and still checks out.
        let ocr = try await test.archive.database.write { db -> Bool in
            let attachment = try Int64.fetchOne(db, sql: "SELECT id FROM attachments WHERE text_status = 'ocr_pending'")!
            let messages = try SearchIndexWriter.messages(containing: attachment, db)
            try SearchIndexWriter.updating(db, messageIDs: messages) {
                try db.execute(sql: "INSERT INTO attachment_text (attachment_id, text, method, extractor_version, extracted_at) VALUES (?, 'TANGERINE-SCAN-1234', 'ocr', 1, 0)",
                               arguments: [attachment])
            }
            return try SearchIndexWriter.integrityCheck(db)
        }
        #expect(ocr)
        let hits = try await test.archive.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH '\"TANGERINE-SCAN-1234\"'")
        }
        #expect(hits == 1)
    }

    @Test func verifyFindsADamagedAttachmentFile() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try Importer(archive: test.archive).importMessage(test.raw(try Fixtures.data("06-"), uid: 1))
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
        let attachment = try #require(test.files(in: test.location.attachmentsDirectory).first)
        var bytes = try Data(contentsOf: attachment)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: attachment)
        let report = try ArchiveVerifier(archive: test.archive).run()
        #expect(!report.isClean)
        #expect(report.failedMessages.count == 1) // its skeleton can no longer rebuild
        #expect(report.failedAttachments.count == 1)
    }

    @Test func mboxExportRoundTrips() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        var messages = try test.fixtureMessages().filter { $0.bytes.count < 1_000_000 }
        // A body line starting with "From " must survive the mbox quoting.
        let tricky = Data("From: a@example.com\r\nSubject: x\r\n\r\nFrom here on\r\n>From quoted\r\n>>From twice\r\nend\r\n".utf8)
        messages.append(test.raw(tricky, uid: 99))
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(messages))
        let file = test.location.root.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString).mbox")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try MboxExport.export(test.archive, account: test.account.id, to: file)
        #expect(result.messages == messages.count)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #expect(throws: MboxExportError.self) { try MboxExport.export(test.archive, account: test.account.id, to: file) }

        let parsed = Self.readMboxrd(try Data(contentsOf: file))
        // mbox has no way to say a message ended without a line break, so those gain one (D-042).
        #expect(Set(parsed) == Set(messages.map { $0.bytes.last == 0x0A ? $0.bytes : $0.bytes + Data([0x0A]) }))
    }

    /// A minimal mboxrd reader, as a mail client would read the file.
    static func readMboxrd(_ data: Data) -> [Data] {
        var messages: [Data] = []
        var current: [UInt8]?
        var lines = [UInt8](data).split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        for line in lines {
            if line.starts(with: Array("From MAILER-DAEMON ".utf8)) {
                if let message = current { messages.append(Data(message.dropLast())) }  // the blank separator line
                current = []
                continue
            }
            var content = line
            if let first = content.firstIndex(where: { $0 != UInt8(ascii: ">") }), first > 0,
               content[first...].starts(with: Array("From ".utf8)) {
                content.removeFirst()
            }
            current? += content + [0x0A]
        }
        if let message = current { messages.append(Data(message.dropLast())) }
        return messages
    }
}
