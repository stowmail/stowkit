import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import ImageIO
import os
import StowCore
import StowSecrets
import Testing
import UniformTypeIdentifiers
@testable import StowSearch
@testable import StowStore

/// A-03 and D-481 (security sweep 1, step 7; D-502): one attachment that hangs
/// or crashes OCR never blocks the queue, and the mark it gets shows.
@Suite(.serialized, .timeLimit(.minutes(1))) struct OCRAttemptTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-ocr-\(UUID().uuidString)")
    let account = AccountID(rawValue: "00000000-0000-4000-8000-0000000000cc")

    /// A blank PNG of the given width: different widths give different attachments.
    static func png(width: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 20))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// An archive with one message holding two scanned images, both waiting for OCR.
    func archive() throws -> Archive {
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        try archive.register(Account(id: account, provider: .microsoft, email: "sam@example.com", displayName: "Main"))
        let parts = [(1, Self.png(width: 20)), (2, Self.png(width: 30))].map { index, data in
            """
            --b\r
            Content-Type: image/png; name="scan\(index).png"\r
            Content-Disposition: attachment; filename="scan\(index).png"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(data.base64EncodedString())\r

            """
        }.joined()
        let text = """
            From: Sam <sam@example.org>\r
            To: sam@example.com\r
            Subject: Scans\r
            Date: Mon, 1 Sep 2025 10:00:00 +0000\r
            Message-ID: <scans@example.org>\r
            MIME-Version: 1.0\r
            Content-Type: multipart/mixed; boundary="b"\r
            \r
            --b\r
            Content-Type: text/plain\r
            \r
            Two scans.\r
            \(parts)--b--\r

            """
        let raw = RawMessage(key: RawMessageKey(accountID: account, folder: "INBOX", uidValidity: 1, uid: 1),
                             internalDate: Date(timeIntervalSince1970: 1_756_720_800), size: text.utf8.count, bytes: Data(text.utf8))
        _ = try Importer(archive: archive).importMessage(raw)
        return archive
    }

    func count(_ archive: Archive, _ condition: String) throws -> Int {
        try archive.database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments WHERE \(condition)")! }
    }

    /// A recogniser that does not return until released, then reads "late".
    final class Stuck: Sendable {
        let gate = DispatchSemaphore(value: 0)
        let entered = OSAllocatedUnfairLock(initialState: 0)
        var recognise: @Sendable (CGImage) throws -> String {
            { [self] _ in
                entered.withLock { $0 += 1 }
                gate.wait()
                return "late"
            }
        }
        func release(_ count: Int) { for _ in 0..<count { gate.signal() } }
    }

    /// A fresh process's limit: its own count of stuck items.
    static func limit(_ duration: Duration) -> TimeLimit {
        TimeLimit(limit: duration, maximumAbandoned: 1, abandoned: OSAllocatedUnfairLock(initialState: 0))
    }

    @Test func aHungItemIsMarkedAndTheNextRunMovesOn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try archive()
        #expect(try OCRQueue(archive: archive).status().pending == 2)
        let stuck = Stuck()
        defer { stuck.release(1) }

        let hanging = OCRQueue(archive: archive, recogniser: stuck.recognise, limit: Self.limit(.milliseconds(200)))
        #expect(throws: OCRQueue.OCRError.timedOut) { try hanging.runNext() }
        #expect(try count(archive, "text_status = 'ocr_failed' AND text_failed_version = \(OCRQueue.version) AND text_attempts = 0") == 1)
        // The same process will not start another while that one is stuck.
        #expect(throws: OCRQueue.OCRError.tooManyStuck) { try hanging.runNext() }
        #expect(try count(archive, "text_status = 'ocr_pending' AND text_attempts = 0") == 1)

        // The next run reads the next item.
        let next = OCRQueue(archive: archive, recogniser: { _ in "Egretmoor receipt" }, limit: Self.limit(.seconds(10)))
        #expect(try next.runNext())
        #expect(try next.runNext() == false)
        #expect(try next.status() == OCRStatus(pending: 0, done: 1, failed: 1, messagesWaiting: 0))
        let hits = try archive.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'egretmoor'")!
        }
        #expect(hits == 1)
    }

    @Test func anItemThatCrashedThreeTimesIsSkippedAndTheQueueMovesOn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try archive()
        let stuck = Stuck()
        let finished = OSAllocatedUnfairLock(initialState: 0)

        // Three runs die while recognising the first item: each left stuck on a
        // thread of its own, then a new queue, as after a restart.
        for crash in 1...3 {
            let queue = OCRQueue(archive: archive, recogniser: stuck.recognise, limit: Self.limit(.seconds(60)))
            Thread.detachNewThread {
                _ = try? queue.runNext()
                finished.withLock { $0 += 1 }
            }
            let deadline = Date().addingTimeInterval(10)
            while stuck.entered.withLock({ $0 }) < crash, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(try count(archive, "text_status = 'ocr_pending' AND text_attempts = \(crash)") == 1)
        }

        // The fourth run marks it failed without reading it, then reads the next.
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let queue = OCRQueue(archive: archive, recogniser: { _ in reads.withLock { $0 += 1 }; return "Plover statement" },
                             limit: Self.limit(.seconds(10)))
        #expect(try queue.runNext())
        #expect(reads.withLock { $0 } == 0)
        #expect(try count(archive, "text_status = 'ocr_failed' AND text_failed_version = \(OCRQueue.version) AND text_attempts = 0") == 1)
        #expect(try queue.runNext())
        #expect(reads.withLock { $0 } == 1)
        #expect(try queue.status() == OCRStatus(pending: 0, done: 1, failed: 1, messagesWaiting: 0))

        // The runs that "crashed" finishing late change nothing.
        stuck.release(3)
        let deadline = Date().addingTimeInterval(10)
        while finished.withLock({ $0 }) < 3, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(try queue.status() == OCRStatus(pending: 0, done: 1, failed: 1, messagesWaiting: 0))
        #expect(try count(archive, "text_status = 'ocr_failed' AND text_failed_version IS NOT NULL") == 1)
    }

    @Test func failedItemsGoBackInTheQueueOnlyForANewerVersion() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try archive()
        let failing = OCRQueue(archive: archive, recogniser: { _ in throw OCRQueue.OCRError.unreadable }, limit: Self.limit(.seconds(10)), version: 1)
        while try failing.runNext() {}
        #expect(try failing.status().failed == 2)

        #expect(try failing.requeueAfterUpdate() == 0)
        let newer = OCRQueue(archive: archive, recogniser: { _ in "Curlew letter" }, limit: Self.limit(.seconds(10)), version: 2)
        #expect(try newer.requeueAfterUpdate() == 2)
        #expect(try newer.status().pending == 2)
        while try newer.runNext() {}
        #expect(try newer.status() == OCRStatus(pending: 0, done: 2, failed: 0, messagesWaiting: 0))
        #expect(try newer.requeueAfterUpdate() == 0)
    }

    @Test func theReaderShowsTheMarkAndDoesNotParseAnUnreadMessage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try archive()
        // Message 1: an image OCR could not read. Message 2: stored whole and unread.
        let failing = OCRQueue(archive: archive, recogniser: { _ in throw OCRQueue.OCRError.unreadable }, limit: Self.limit(.seconds(10)))
        #expect(try failing.runNext())
        let bytes = Data("From: a@example.org\r\nSubject: Unread\r\n\r\nNever parsed.\r\n".utf8)
        let raw = RawMessage(key: RawMessageKey(accountID: account, folder: "INBOX", uidValidity: 1, uid: 2),
                             internalDate: Date(timeIntervalSince1970: 1_756_720_900), size: bytes.count, bytes: bytes)
        guard case .imported(let unread) = try Importer(archive: archive).storeUnread(raw) else {
            Issue.record("not stored")
            return
        }

        let reader = MessageReader(archive: archive)
        let first = try #require(try await reader.message(1, bodyLimit: 1000))
        #expect(first.textIncomplete)
        #expect(first.attachments.map(\.textUnreadable) == [true, false])
        #expect(first.subject == "Scans")

        let second = try #require(try await reader.message(unread, bodyLimit: 1000))
        #expect(second.textIncomplete)
        #expect(second.subject == nil && second.body == nil && second.attachments.isEmpty)
        let body = try #require(try await reader.body(of: unread))
        #expect(body.html == nil && body.plain == nil)
        #expect(try archive.rawMessage(unread) == bytes)

        // Encoded before the mark existed: decodes as not marked.
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        encoded["textIncomplete"] = nil
        encoded["attachments"] = (encoded["attachments"] as! [[String: Any]]).map { var a = $0; a["textUnreadable"] = nil; return a }
        let old = try JSONDecoder().decode(MessageDetail.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(!old.textIncomplete && old.attachments.allSatisfy { !$0.textUnreadable })
    }
}
