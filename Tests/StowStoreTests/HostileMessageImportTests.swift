import CryptoKit
import Foundation
import Testing
@testable import StowStore

/// A-01 and A-02 (security sweep 1) end to end: a whole message built to
/// trip both decoders is parsed and stored promptly, and hostile MIME
/// parameters decode in linear time.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HostileMessageImportTests {
    static func hostileMessage() -> Data {
        let subject = String(repeating: "=?", count: 256 << 10)
        let body = String(repeating: "<a", count: 1 << 20)
        return Data("""
            From: Sam <sam@example.org>\r
            To: sam@example.com\r
            Subject: \(subject)\r
            Date: Mon, 1 Sep 2025 10:00:00 +0000\r
            Message-ID: <hostile@example.org>\r
            MIME-Version: 1.0\r
            Content-Type: text/html; charset=utf-8\r
            \r
            \(body)\r

            """.utf8)
    }

    @Test func parsesPromptly() {
        let (parsed, seconds) = timed { MIMEParser().parse(Self.hostileMessage()) }
        #expect(seconds < 2, "took \(seconds) s")
        #expect(parsed.headers.subject?.hasPrefix("=?=?") == true)
        #expect(parsed.textFromHTML?.hasPrefix("<a<a") == true)
    }

    @Test func importsPromptlyAndIsStored() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let raw = test.raw(Self.hostileMessage(), uid: 1)
        let (outcome, seconds) = try timed { try Importer(archive: test.archive).importMessage(raw) }
        #expect(seconds < 2, "took \(seconds) s")
        guard case .imported = outcome else {
            Issue.record("expected imported, got \(outcome)")
            return
        }
        #expect(try test.count("messages") == 1)
    }

    @Test func hostileMIMEParameter() {
        let name = String(repeating: "=?x?", count: (1 << 20) / 4)
        let (field, seconds) = timed { ContentField.parse("attachment; filename=\"\(name)\"") }
        #expect(seconds < 1, "took \(seconds) s")
        #expect(field[parameter: "filename"] == name)
    }
}

/// Every fixture's decoded headers, file names and HTML text, hashed. The
/// value was recorded on the code before the A-01 and A-02 fixes
/// (engine 711062a), so a change here means the fixes changed what real
/// mail decodes to (security sweep 1, "Stop and ask if").
@Suite struct FixtureDecodingTests {
    static let recorded = "9afdfd875e85db7643d9a08985b62bda35be1611f8802fd4aace49a7701bf406"

    @Test func fixturesDecodeAsBefore() throws {
        var hasher = SHA256()
        for file in try Fixtures.allFiles() {
            let parsed = MIMEParser().parse(try Data(contentsOf: Fixtures.directory.appendingPathComponent(file)))
            let h = parsed.headers
            var lines = [file, h.subject ?? "-"]
            lines += (h.from + h.to + h.cc + h.replyTo).map { "\($0.name ?? "-") <\($0.address)>" }
            lines += parsed.attachments.map { $0.filename ?? "-" }
            lines.append(parsed.textFromHTML ?? "-")
            hasher.update(data: Data(lines.joined(separator: "\n").utf8))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.recorded)
    }
}
