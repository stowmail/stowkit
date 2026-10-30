import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// D-521, D-522: the provider's DMARC result for the From domain is stored with
/// every message at import, and a backfill reads it for messages stored before.
/// The test account is Microsoft, so only a topmost `mx.microsoft.com` field counts.
@Suite(.serialized) struct SenderDMARCStoreTests {
    static let pass = "mx.microsoft.com 1; spf=pass (sender IP is 192.0.2.1) smtp.mailfrom=paypal.com; dkim=pass (signature was verified) header.d=paypal.com;dmarc=pass action=none header.from=paypal.com;compauth=pass reason=100"
    static let bestGuess = "mx.microsoft.com 1; spf=pass (sender IP is 192.0.2.1) smtp.mailfrom=paypal.com;dmarc=bestguesspass action=none header.from=paypal.com;compauth=pass reason=109"

    /// A synthetic message; `authentication` is the topmost Authentication-Results field, if any.
    static func message(_ n: Int, authentication: String?) -> Data {
        let field = authentication.map { "Authentication-Results: \($0)\r\n" } ?? ""
        return Data("""
            \(field)From: PayPal <service@paypal.com>\r
            To: sam@example.com\r
            Subject: Receipt \(n)\r
            Message-ID: <r\(n)@example.org>\r
            \r
            Thank you.\r

            """.utf8)
    }

    /// What each of `count` messages should store: pass, fail and none in turn.
    static func expected(_ n: Int) -> SenderDMARC { [SenderDMARC.pass, .fail, .none][n % 3] }

    static func authentication(_ n: Int) -> String? {
        switch expected(n) {
        case .pass: pass
        case .fail: bestGuess
        case .none: nil
        }
    }

    /// Imports `count` messages and returns their IDs in order.
    func importMessages(_ test: TestArchive, count: Int) throws -> [StoredMessageID] {
        try (0..<count).map { n in
            guard case .imported(let id) = try Importer(archive: test.archive)
                .importMessage(test.raw(Self.message(n, authentication: Self.authentication(n)), uid: UInt32(n + 1)))
            else { throw CocoaError(.fileWriteUnknown) }
            return id
        }
    }

    func stored(_ test: TestArchive) throws -> [StoredMessageID: String?] {
        try test.archive.database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, sender_dmarc FROM messages").map {
                ($0["id"] as StoredMessageID, $0["sender_dmarc"] as String?)
            })
        }
    }

    /// As an archive from before v3, or rows an older build inserted.
    func forget(_ test: TestArchive) throws {
        try test.archive.database.write { db in try db.execute(sql: "UPDATE messages SET sender_dmarc = NULL") }
    }

    // MARK: - Import

    @Test func importStoresTheProvidersResultAndNeverNothing() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let ids = try importMessages(test, count: 6)
        let values = try stored(test)
        for (n, id) in ids.enumerated() {
            #expect(values[id] == Self.expected(n).rawValue, "message \(n)")
        }
        // Every fixture too, whatever its headers: a value, never NULL.
        _ = try await Importer(archive: test.archive).importAll(from: MemorySource(try test.fixtureMessages().map {
            test.raw($0.bytes, uid: $0.key.uid + 100)
        }))
        #expect(try test.count("messages") == 31)
        #expect(try test.count("messages", "sender_dmarc IS NULL") == 0)
        #expect(try SenderDMARCBackfill(archive: test.archive).pending() == 0)
    }

    /// A message stored unread (D-502) has no headers read, so `none`; when a
    /// newer parser reads it again, the result comes from its headers.
    @Test func aMessageStoredUnreadGetsNoneUntilItIsReadAgain() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let older = Importer(archive: test.archive, extractor: TextExtractor(), parserVersion: MIMEParser.version - 1)
        guard case .imported(let id) = try older.storeUnread(test.raw(Self.message(0, authentication: Self.pass), uid: 1)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        #expect(try stored(test)[id] == "none")
        #expect(try Importer(archive: test.archive).retryMarkedMessages().read == 1)
        #expect(try stored(test)[id] == "pass")
    }

    // MARK: - Backfill

    @Test func theBackfillReadsOlderMessagesInBatches() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let ids = try importMessages(test, count: 11)
        try forget(test)
        // D-522's queries, whose plans `SchemaV3Tests` check use only the partial index.
        #expect(SenderDMARCBackfill.batchSQL == BackfillQueries.batch)
        #expect(SenderDMARCBackfill.pendingSQL == BackfillQueries.count)
        let backfill = SenderDMARCBackfill(archive: test.archive, batchSize: 4)
        #expect(try backfill.pending() == 11)
        let summary = try backfill.run()
        #expect(summary == SenderDMARCBackfillSummary(read: 11, unreadable: 0, stopped: false))
        let values = try stored(test)
        for (n, id) in ids.enumerated() { #expect(values[id] == Self.expected(n).rawValue, "message \(n)") }
        #expect(try backfill.pending() == 0)
        // Done: the next daemon start reads nothing.
        #expect(try backfill.run() == SenderDMARCBackfillSummary())
    }

    /// Stopped after any number of messages, inside a batch or on its edge, the
    /// backfill keeps what it read, and the next run reads only the rest.
    @Test(arguments: [0, 1, 3, 4, 5, 8, 10, 11])
    func aBackfillStoppedPartWayResumesWhereItStopped(after stop: Int) throws {
        let test = try TestArchive()
        defer { test.remove() }
        let ids = try importMessages(test, count: 11)
        try forget(test)
        let backfill = SenderDMARCBackfill(archive: test.archive, batchSize: 4)

        var asked = 0
        let first = try backfill.run(shouldStop: {
            defer { asked += 1 }
            return asked >= stop
        })
        #expect(first.read == stop)
        #expect(first.stopped == (stop < 11))
        var values = try stored(test)
        for (n, id) in ids.enumerated() {
            #expect(values[id] == (n < stop ? Self.expected(n).rawValue : nil), "message \(n), stopped after \(stop)")
        }
        #expect(try backfill.pending() == 11 - stop)

        let second = try backfill.run()
        #expect(second == SenderDMARCBackfillSummary(read: 11 - stop, unreadable: 0, stopped: false))
        values = try stored(test)
        for (n, id) in ids.enumerated() { #expect(values[id] == Self.expected(n).rawValue, "message \(n)") }
        #expect(try backfill.pending() == 0)
    }

    /// A raw file that is gone or will not open gives `none`, so the message
    /// leaves the index and is not read again at every start (D-522); the
    /// messages after it are read as usual.
    @Test func aMessageWhoseRawFileCannotBeReadGetsNone() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let ids = try importMessages(test, count: 6)
        try forget(test)
        let hashes = try test.archive.database.read { db in
            try [ids[0], ids[3]].map { try Data.fetchOne(db, sql: "SELECT raw_hash FROM messages WHERE id = ?", arguments: [$0])! }
        }
        try Data("not a Stow file".utf8).write(to: test.archive.rawFiles.url(for: hashes[0]))   // message 0 would say pass
        try FileManager.default.removeItem(at: test.archive.rawFiles.url(for: hashes[1]))       // message 3 would say pass

        let backfill = SenderDMARCBackfill(archive: test.archive, batchSize: 4)
        #expect(try backfill.run() == SenderDMARCBackfillSummary(read: 4, unreadable: 2, stopped: false))
        let values = try stored(test)
        for (n, id) in ids.enumerated() {
            #expect(values[id] == ([0, 3].contains(n) ? "none" : Self.expected(n).rawValue), "message \(n)")
        }
        #expect(try backfill.pending() == 0)
        #expect(try backfill.run() == SenderDMARCBackfillSummary())
    }

    /// A value already there (set by import while the backfill ran) is never overwritten.
    @Test func theBackfillWritesOnlyWhatIsStillMissing() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let ids = try importMessages(test, count: 3)
        try forget(test)
        let backfill = SenderDMARCBackfill(archive: test.archive, batchSize: 4)
        _ = try backfill.run(shouldStop: {
            // Between reading the batch and writing it, something else stores a result.
            try? test.archive.database.write { db in
                try db.execute(sql: "UPDATE messages SET sender_dmarc = 'fail' WHERE id = ? AND sender_dmarc IS NULL", arguments: [ids[0]])
            }
            return false
        })
        #expect(try stored(test)[ids[0]] == "fail")
        #expect(try stored(test)[ids[1]] == "fail")
        #expect(try stored(test)[ids[2]] == "none")
    }
}
