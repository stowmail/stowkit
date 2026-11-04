import CryptoKit
import Foundation
import StowCore
import StowSecrets
import Testing
@testable import StowMCP
@testable import StowSearch
@testable import StowStore

/// Search, the message reader and MCP say when a message came from an imported file (D-567).
@Suite(.serialized) struct ImportedMarkTests {
    @Test func importedMailIsMarkedInSearchTheReaderAndMCP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-imported-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        let account = AccountID(rawValue: "00000000-0000-4000-8000-0000000000ee")
        try archive.register(Account(id: account, provider: .gmail, email: "sam@example.com", displayName: "S"))
        let synced = "From: a@example.org\r\nSubject: Quince synced\r\nMessage-ID: <s@example.org>\r\n\r\nquince\r\n"
        _ = try Importer(archive: archive).importMessage(RawMessage(
            key: RawMessageKey(accountID: account, folder: "[Gmail]/All Mail", uidValidity: 1, uid: 1),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000), size: synced.utf8.count, bytes: Data(synced.utf8)))
        let file = root.appendingPathComponent("Takeout.mbox")
        try Data("""
            From 1@xxx Mon Sep 18 10:12:13 +0000 2023\r
            X-GM-THRID: 5\r
            X-Gmail-Labels: Spam\r
            From: b@example.org\r
            Subject: Quince imported\r
            Message-ID: <i@example.org>\r
            \r
            quince\r
            \r

            """.utf8).write(to: file)
        _ = try MboxImporter(archive: archive, importer: Importer(archive: archive)).run(file, account: account)

        let searcher = MessageSearcher(database: archive.database)
        let hits = try await searcher.search(QueryParser.parse("quince in:anywhere"))
        #expect(Dictionary(uniqueKeysWithValues: hits.map { ($0.subject ?? "", $0.isImported) })
            == ["Quince synced": false, "Quince imported": true])
        let id = try #require(hits.first { $0.isImported }?.messageID)
        let detail = try #require(try await MessageReader(archive: archive).message(id, bodyLimit: 10))
        #expect(detail.isImported && detail.sourceState == .spam)

        let lines = ArchiveTools.headerLines(detail)
        #expect(lines.contains { $0.hasPrefix("Date: ") && $0.hasSuffix("(imported)") })
        #expect(lines.contains("Source: imported from a file, not downloaded from the mailbox"))
        #expect(lines.contains("Marked spam in the imported file (kept in the archive)"))
        #expect(!lines.contains { $0.hasPrefix("In the mailbox:") })
    }
}
