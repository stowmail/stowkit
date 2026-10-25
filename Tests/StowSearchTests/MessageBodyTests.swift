import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// R9: the displayable body for the reader (D-059, D-409). Every message is synthetic, built here.
struct MessageBodyTests {
    final class Fixture: @unchecked Sendable {
        let root: URL
        let archive: Archive
        let account = AccountID(rawValue: "00000000-0000-4000-8000-0000000000f2")
        let logo = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        var uid: UInt32 = 0

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-body-\(UUID().uuidString)")
            archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
            try archive.register(Account(id: account, provider: .gmail, email: "sam@example.net", displayName: "Home"))
        }

        func store(_ bytes: Data) throws -> StoredMessageID {
            uid += 1
            let raw = RawMessage(key: RawMessageKey(accountID: account, folder: "[Gmail]/All Mail", uidValidity: 1, uid: uid),
                                 internalDate: Date(timeIntervalSince1970: 1_756_684_800), size: bytes.count, bytes: bytes)
            guard case .imported(let id) = try Importer(archive: archive).importMessage(raw) else { throw CocoaError(.fileWriteUnknown) }
            return id
        }

        func store(_ text: String) throws -> StoredMessageID { try store(Data(text.utf8)) }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// HTML in ISO-8859-1, quoted-printable, with a plain UTF-8 alternative,
    /// two `cid:` images (one referred to twice, one percent-escaped) and a remote image.
    static func alternative(logo: Data) -> String {
        """
        From: Caf\u{e9} <news@cafe.example>\r
        To: sam@example.net\r
        Subject: Menu\r
        Message-ID: <menu-1@cafe.example>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="alt"\r
        \r
        --alt\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        Caf\u{e9} menu, plain\r
        --alt\r
        Content-Type: multipart/related; boundary="rel"\r
        \r
        --rel\r
        Content-Type: text/html; charset="ISO-8859-1"\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <html><body><p>Caf=E9 cr=E8me</p><img src=3D"cid:logo.1@cafe.example"><img src=3D"CID:dot%2B1@cafe.=\r
        example"><div style=3D"background:url(cid:logo.1@cafe.example)"></div><img src=3D"https://track.example/p=\r
        .gif"></body></html>\r
        --rel\r
        Content-Type: image/png; name="logo.png"\r
        Content-Transfer-Encoding: base64\r
        Content-ID: <logo.1@cafe.example>\r
        Content-Disposition: inline; filename="logo.png"\r
        \r
        \(logo.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r
        --rel\r
        Content-Type: image/gif\r
        Content-Transfer-Encoding: base64\r
        Content-ID: <dot+1@cafe.example>\r
        \r
        R0lGODlhAQABAAAAACw=\r
        --rel--\r
        --alt--\r

        """
    }

    @Test func htmlAndPlainComeBackWithTheirCharsetsAndCIDReferences() async throws {
        let f = try Fixture()
        let id = try f.store(Self.alternative(logo: f.logo))
        let body = try #require(try await MessageReader(archive: f.archive).body(of: id))
        let html = try #require(body.html)
        #expect(html.contains("<p>Caf\u{e9} cr\u{e8}me</p>"))
        #expect(html.contains("src=\"cid:logo.1@cafe.example\""))
        // The HTML is the source, untouched: the remote image is still there for the web view to block.
        #expect(html.contains("https://track.example/p.gif"))
        #expect(body.plain == "Caf\u{e9} menu, plain")
        #expect(body.contentIDs == ["logo.1@cafe.example", "dot+1@cafe.example"])
        // Each listed ID is one the inline part call serves.
        for contentID in body.contentIDs {
            #expect(try await MessageReader(archive: f.archive).inlinePart(message: id, contentID: contentID) != nil)
        }
    }

    @Test func plainOnlyInWindows1251() async throws {
        let f = try Fixture()
        var bytes = Data("""
            From: sam@example.net\r
            To: jo@example.org\r
            Subject: Privet\r
            MIME-Version: 1.0\r
            Content-Type: text/plain; charset=windows-1251\r
            Content-Transfer-Encoding: 8bit\r
            \r

            """.utf8)
        bytes.append(contentsOf: [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x0D, 0x0A])  // "Привет" in Windows-1251
        let body = try #require(try await MessageReader(archive: f.archive).body(of: try f.store(bytes)))
        #expect(body.html == nil)
        #expect(body.plain == "\u{41F}\u{440}\u{438}\u{432}\u{435}\u{442}\n")
        #expect(body.contentIDs.isEmpty)
    }

    @Test func htmlOnlyInShiftJIS() async throws {
        let f = try Fixture()
        var bytes = Data("""
            From: shop@example.jp\r
            To: sam@example.net\r
            Subject: Order\r
            MIME-Version: 1.0\r
            Content-Type: text/html; charset=Shift_JIS\r
            \r
            <p>
            """.utf8)
        bytes.append(contentsOf: [0x93, 0xFA, 0x96, 0x7B])  // "日本" in Shift_JIS
        bytes.append(Data("</p>\r\n".utf8))
        let body = try #require(try await MessageReader(archive: f.archive).body(of: try f.store(bytes)))
        #expect(body.html == "<p>\u{65E5}\u{672C}</p>\r\n")
        #expect(body.plain == nil)
    }

    @Test func attachedTextFilesAreNotBody() async throws {
        let f = try Fixture()
        let id = try f.store("""
            From: sam@example.net\r
            To: jo@example.org\r
            Subject: Notes\r
            MIME-Version: 1.0\r
            Content-Type: multipart/mixed; boundary="m"\r
            \r
            --m\r
            Content-Type: text/plain\r
            \r
            See attached.\r
            --m\r
            Content-Type: text/html; name="page.html"\r
            Content-Disposition: attachment; filename="page.html"\r
            \r
            <p>attached page</p>\r
            --m--\r

            """)
        let body = try #require(try await MessageReader(archive: f.archive).body(of: id))
        #expect(body.plain == "See attached.")
        #expect(body.html == nil)
    }

    @Test func storedTextIsUnchanged() throws {
        // `displayBody` must not change what import stores (MIMEParser.version stays the same).
        let raw = Data(Self.alternative(logo: Data([1, 2, 3])).utf8)
        let parsed = MIMEParser().parse(raw)
        #expect(parsed.textPlain == "Caf\u{e9} menu, plain")
        #expect(parsed.textFromHTML?.contains("<") == false)
        #expect(parsed.attachments.count == 2)
        #expect(MIMEParser.version == 1)
    }

    @Test func unknownMessageAndDatabaseOnlyReader() async throws {
        let f = try Fixture()
        let id = try f.store(Self.alternative(logo: f.logo))
        #expect(try await MessageReader(archive: f.archive).body(of: id + 99) == nil)
        await #expect(throws: MessageReaderError.noFileKey) {
            _ = try await MessageReader(database: f.archive.database).body(of: id)
        }
    }

    @Test func nothingDecryptedIsWrittenToDisk() async throws {
        let f = try Fixture()
        let id = try f.store(Self.alternative(logo: f.logo))
        func files() -> Set<String> {
            Set((FileManager.default.enumerator(atPath: f.root.path)?.allObjects as? [String]) ?? [])
                .filter { !$0.hasPrefix("archive.sqlite") }
        }
        let before = files()
        let temporary = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        let body = try await MessageReader(archive: f.archive).body(of: id)
        #expect(body?.html != nil)
        #expect(files() == before)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        // Other tests run in parallel and make their own folders; none of the new entries may hold the body.
        for name in after.subtracting(temporary) {
            let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
            if let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) {
                #expect(!text.contains("cr\u{e8}me"))
            }
        }
    }

    @Test func contentIDsInHTML() {
        #expect(MessageBody.contentIDs(inHTML: #"<img src='cid:a@x'><img src="cid:%3Cb@x%3E"> cid:a@x"#) == ["a@x", "b@x"])
        #expect(MessageBody.contentIDs(inHTML: "<p>acid:rain is not a reference</p>").isEmpty)
        #expect(MessageBody.contentIDs(inHTML: "<p>plain</p>").isEmpty)
    }
}
