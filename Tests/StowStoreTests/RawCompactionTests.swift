import Foundation
import Testing
@testable import StowStore

@Suite struct RawCompactionTests {
    let parser = MIMEParser()

    func hashOf(_ data: Data) -> Data {
        TestArchive.randomKeysForHashing.hash(of: data)
    }

    @Test func compactionIsReversibleOnEveryFixture() throws {
        var compacted = 0
        for file in try Fixtures.allFiles() {
            let raw = try Data(contentsOf: Fixtures.directory.appendingPathComponent(file))
            let parsed = parser.parse(raw)
            guard let skeleton = RawCompaction.compact(raw, parsed: parsed, hashOf: hashOf) else { continue }
            compacted += 1
            #expect(skeleton.count < raw.count, "\(file)")
            let store = Dictionary(parsed.attachments.map { (hashOf($0.data).map { String(format: "%02x", $0) }.joined(), $0.data) },
                                   uniquingKeysWith: { first, _ in first })
            #expect(try RawCompaction.expand(skeleton, attachment: { store[$0] }) == raw, "\(file)")
        }
        // Every fixture with an attachment of 64 bytes or more compacts: 04 to 09 and 24.
        // (10 and 14 only have tiny attachments, which are left inline.)
        #expect(compacted == 7)
    }

    @Test func largeAttachmentShrinksToAlmostNothing() throws {
        let raw = try Fixtures.data("05-")
        let skeleton = try #require(RawCompaction.compact(raw, parsed: parser.parse(raw), hashOf: hashOf))
        #expect(skeleton.count < 4096)
    }

    @Test func missingAttachmentFailsLoudly() throws {
        let raw = try Fixtures.data("06-")
        let skeleton = try #require(RawCompaction.compact(raw, parsed: parser.parse(raw), hashOf: hashOf))
        #expect(throws: RawCompactionError.attachmentMissing) {
            try RawCompaction.expand(skeleton, attachment: { _ in nil })
        }
    }

    @Test func irregularBase64StaysInline() throws {
        // Line lengths vary, so re-encoding cannot reproduce it: nothing is cut.
        let body = "QUFB\r\nQUFBQUFBQUFB\r\nQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB\r\n"
        let raw = Data("""
            From: a@example.com\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r
            Content-Disposition: attachment; filename=x.bin\r\n\r\n\(body)
            """.utf8)
        #expect(RawCompaction.compact(raw, parsed: parser.parse(raw), hashOf: hashOf) == nil)
    }
}

extension TestArchive {
    /// A file store used only to compute keyed hashes in tests.
    static let randomKeysForHashing = EncryptedFileStore(
        directory: FileManager.default.temporaryDirectory, kind: .attachment, keys: randomKeys())
}
