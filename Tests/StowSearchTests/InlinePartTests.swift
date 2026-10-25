import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// R8: inline images by Content-ID (D-059, D-405). The message is synthetic, built here.
struct InlinePartTests {
    final class Fixture: @unchecked Sendable {
        let root: URL
        let archive: Archive
        let account = AccountID(rawValue: "00000000-0000-4000-8000-0000000000f1")
        /// Bytes that are not valid text, so any re-encoding would show.
        let logo = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let small = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
        var messageID: StoredMessageID = 0

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-inline-\(UUID().uuidString)")
            archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
            try archive.register(Account(id: account, provider: .gmail, email: "sam@example.net", displayName: "Home"))
            let text = """
                From: Shop <news@shop.example>\r
                To: sam@example.net\r
                Subject: Your logo\r
                Message-ID: <inline-1@shop.example>\r
                MIME-Version: 1.0\r
                Content-Type: multipart/related; boundary="b1"\r
                \r
                --b1\r
                Content-Type: text/html; charset=utf-8\r
                \r
                <p><img src="cid:logo.123@shop.example"><img src="cid:dot%2B1@shop.example"></p>\r
                --b1\r
                Content-Type: image/png; name="logo.png"\r
                Content-Transfer-Encoding: base64\r
                Content-ID: <logo.123@shop.example>\r
                Content-Disposition: inline; filename="logo.png"\r
                \r
                \(logo.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r
                --b1\r
                Content-Type: image/gif\r
                Content-Transfer-Encoding: base64\r
                Content-ID: <dot+1@shop.example>\r
                \r
                \(small.base64EncodedString())\r
                --b1--\r

                """
            let raw = RawMessage(key: RawMessageKey(accountID: account, folder: "[Gmail]/All Mail", uidValidity: 1, uid: 1),
                                 internalDate: Date(timeIntervalSince1970: 1_756_684_800), size: text.utf8.count, bytes: Data(text.utf8))
            guard case .imported(let id) = try Importer(archive: archive).importMessage(raw) else { throw CocoaError(.fileWriteUnknown) }
            messageID = id
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func cidImageComesBackByteForByte() async throws {
        let f = try Fixture()
        let reader = MessageReader(archive: f.archive)
        let part = try #require(try await reader.inlinePart(message: f.messageID, contentID: "cid:logo.123@shop.example"))
        #expect(part.data == f.logo)
        #expect(part.declaredType == "image/png")
        #expect(part.contentID == "logo.123@shop.example")
        #expect(part.filename == "logo.png")
        // The same part by its bare ID, with angle brackets, and percent-escaped as HTML writes it.
        #expect(try await reader.inlinePart(message: f.messageID, contentID: "logo.123@shop.example")?.data == f.logo)
        #expect(try await reader.inlinePart(message: f.messageID, contentID: "<logo.123@shop.example>")?.data == f.logo)
        #expect(try await reader.inlinePart(message: f.messageID, contentID: "cid:dot%2B1@shop.example")?.data == f.small)
    }

    @Test func attachmentBytesByIndex() async throws {
        // D-410: the reader's Quick Look and Save; numbered like MessageDetail.attachments.
        let f = try Fixture()
        let reader = MessageReader(archive: f.archive)
        let detail = try #require(try await reader.message(f.messageID, bodyLimit: 0))
        let first = try #require(try await reader.attachmentData(message: f.messageID, index: 1))
        #expect(first.data == f.logo)
        #expect(first.info == detail.attachments[0])
        #expect(try await reader.attachmentData(message: f.messageID, index: 2)?.data == f.small)
        #expect(try await reader.attachmentData(message: f.messageID, index: 3) == nil)
        #expect(try await reader.attachmentData(message: f.messageID, index: 0) == nil)
        #expect(try await reader.attachmentData(message: f.messageID + 99, index: 1) == nil)
        await #expect(throws: MessageReaderError.noFileKey) {
            _ = try await MessageReader(database: f.archive.database).attachmentData(message: f.messageID, index: 1)
        }
    }

    @Test func unknownIDOrMessageGivesNil() async throws {
        let f = try Fixture()
        let reader = MessageReader(archive: f.archive)
        #expect(try await reader.inlinePart(message: f.messageID, contentID: "cid:missing@shop.example") == nil)
        #expect(try await reader.inlinePart(message: f.messageID, contentID: "") == nil)
        #expect(try await reader.inlinePart(message: f.messageID + 99, contentID: "cid:logo.123@shop.example") == nil)
    }

    @Test func aDatabaseOnlyReaderRefuses() async throws {
        let f = try Fixture()
        let reader = MessageReader(database: f.archive.database)
        await #expect(throws: MessageReaderError.noFileKey) {
            _ = try await reader.inlinePart(message: f.messageID, contentID: "cid:logo.123@shop.example")
        }
    }

    @Test func nothingDecryptedIsWrittenToDisk() async throws {
        let f = try Fixture()
        func files() -> Set<String> {
            Set((FileManager.default.enumerator(atPath: f.root.path)?.allObjects as? [String]) ?? [])
                .filter { !$0.hasPrefix("archive.sqlite") }
        }
        let before = files()
        let temporary = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        _ = try await MessageReader(archive: f.archive).inlinePart(message: f.messageID, contentID: "cid:logo.123@shop.example")
        #expect(files() == before)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        // Other tests run in parallel and make their own folders; none of the new entries may hold the image.
        for name in after.subtracting(temporary) {
            let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
            if let data = FileManager.default.contents(atPath: path) { #expect(data != f.logo) }
        }
    }
}
