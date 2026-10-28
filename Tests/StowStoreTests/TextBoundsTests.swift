import Foundation
import os
import Testing
@testable import StowStore

/// D-481 without the schema (security sweep 1, step 6): reading text has a
/// size bound per part and PDFKit a time bound, and the message is stored
/// either way (D-495).
@Suite(.serialized, .timeLimit(.minutes(1))) struct TextBoundsTests {
    static let limit = TextExtractor.maximumTextBytes

    static func message(body: String, contentType: String = "text/plain; charset=utf-8") -> Data {
        Data("""
            From: Sam <sam@example.org>\r
            To: sam@example.com\r
            Subject: Bounds\r
            Date: Mon, 1 Sep 2025 10:00:00 +0000\r
            Message-ID: <bounds@example.org>\r
            MIME-Version: 1.0\r
            Content-Type: \(contentType)\r
            \r
            \(body)\r

            """.utf8)
    }

    static let oversize = String(repeating: "word ", count: (limit + (1 << 20)) / 5)

    @Test func oversizeBodyTextIsCutAndTheMessageStored() throws {
        let parsed = MIMEParser().parse(Self.message(body: Self.oversize))
        let text = try #require(parsed.textPlain)
        #expect(text.utf8.count <= Self.limit)
        #expect(text.utf8.count > Self.limit - 16)
        #expect(parsed.warnings.contains("body text cut for search at 10 MB"))

        let test = try TestArchive()
        defer { test.remove() }
        let raw = test.raw(Self.message(body: Self.oversize), uid: 1)
        guard case .imported = try Importer(archive: test.archive).importMessage(raw) else {
            Issue.record("not imported")
            return
        }
        #expect(try test.count("messages", "parse_status = 'degraded'") == 1)
    }

    @Test func oversizeTextAttachmentIsCutNotSkipped() {
        let attachment = ParsedAttachment(partPath: "2", filename: "big.txt", declaredMimeType: "text/plain",
                                          disposition: .attachment, contentID: nil, data: Data(Self.oversize.utf8),
                                          encodedRange: 0..<0, transferEncoding: nil)
        let result = TextExtractor().extract(attachment)
        #expect(result.status == .extracted)
        #expect(result.text?.count == TextExtractor.maximumCharacters)
    }

    static func pdfMessage() -> Data {
        message(body: """
            --b\r
            Content-Type: text/plain\r
            \r
            See attached.\r
            --b\r
            Content-Type: application/pdf; name="hangs.pdf"\r
            Content-Disposition: attachment; filename="hangs.pdf"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(Data("%PDF-1.4 stand-in".utf8).base64EncodedString())\r
            --b--
            """, contentType: "multipart/mixed; boundary=\"b\"")
    }

    /// A stand-in for PDFKit that never returns until the test lets it go.
    final class Hang: Sendable {
        let gate = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var extract: @Sendable (Data) -> ExtractionResult {
            { [self] _ in
                calls.withLock { $0 += 1 }
                gate.wait()
                return ExtractionResult(status: .extracted, text: "late", method: .pdfkit)
            }
        }
        func release(_ count: Int) { for _ in 0..<count { gate.signal() } }
    }

    @Test func hungPDFTimesOutAndTheMessageIsStored() throws {
        let hang = Hang()
        let abandoned = OSAllocatedUnfairLock(initialState: 0)
        let extractor = TextExtractor(pdfText: hang.extract, pdfLimit: .milliseconds(200), abandoned: abandoned)
        let test = try TestArchive()
        defer { test.remove() }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = try Importer(archive: test.archive, extractor: extractor).importMessage(test.raw(Self.pdfMessage(), uid: 1))
        #expect(clock.now - start < .seconds(5))
        guard case .imported = outcome else {
            Issue.record("not imported")
            return
        }
        #expect(try test.count("attachments", "text_status = 'unsupported'") == 1)
        #expect(abandoned.withLock { $0 } == 1)

        // Once the stuck call finishes, it no longer counts.
        hang.release(1)
        let deadline = clock.now + .seconds(5)
        while abandoned.withLock({ $0 }) > 0, clock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(abandoned.withLock { $0 } == 0)
    }

    @Test func tooManyStuckPDFsGetNoMoreThreads() {
        let hang = Hang()
        let abandoned = OSAllocatedUnfairLock(initialState: 0)
        let extractor = TextExtractor(pdfText: hang.extract, pdfLimit: .milliseconds(50), abandoned: abandoned)
        for _ in 0..<(TextExtractor.maximumAbandoned + 2) {
            #expect(extractor.pdf(Data()) == .unsupported)
        }
        #expect(hang.calls.withLock { $0 } == TextExtractor.maximumAbandoned)
        hang.release(TextExtractor.maximumAbandoned)
    }
}
