import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// A-20: an export that stops part way leaves nothing under the final name,
/// so the retry works once the cause is fixed.
@Suite(.serialized) struct InterruptedExportTests {
    /// Three messages; the second one's stored file is moved away for the first try.
    static func archiveWithAMissingFile() throws -> (TestArchive, missing: URL, aside: URL) {
        let test = try TestArchive()
        for uid in 1...3 {
            let text = "From: a@example.org\r\nSubject: m\(uid)\r\nMessage-ID: <m\(uid)@example.org>\r\n\r\nline \(uid)\r\n"
            _ = try Importer(archive: test.archive).importMessage(test.raw(Data(text.utf8), uid: UInt32(uid)))
        }
        let hash = try test.archive.database.read { db in
            try Data.fetchOne(db, sql: "SELECT raw_hash FROM messages ORDER BY internal_date, id LIMIT 1 OFFSET 1")!
        }
        let missing = test.archive.rawFiles.url(for: hash)
        let aside = test.location.root.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: missing, to: aside)
        return (test, missing, aside)
    }

    func visibleFiles(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
    }

    @Test func aFailedExportLeavesNoFileAndTheRetryWorks() throws {
        let (test, missing, aside) = try Self.archiveWithAMissingFile()
        defer { test.remove() }
        let folder = test.location.root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("sam.mbox")

        #expect(throws: (any Error).self) { try MboxExport.export(test.archive, account: test.account.id, to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try visibleFiles(folder).isEmpty)

        try FileManager.default.moveItem(at: aside, to: missing)
        let result = try MboxExport.export(test.archive, account: test.account.id, to: url)
        #expect(result.messages == 3)
        #expect(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\nFrom MAILER-DAEMON ").count == 3)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        // Hidden left-overs from a killed run never block a retry; a failed run cleans up its own.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["sam.mbox"])
    }

    @Test func aFailedExportEverythingCanBeRetried() throws {
        let (test, missing, aside) = try Self.archiveWithAMissingFile()
        defer { test.remove() }
        let folder = test.location.root.appendingPathComponent("everything", isDirectory: true)
        #expect(throws: (any Error).self) { try MboxExport.exportAll(test.archive, to: folder) }
        #expect(try visibleFiles(folder).isEmpty)

        try FileManager.default.moveItem(at: aside, to: missing)
        let results = try MboxExport.exportAll(test.archive, to: folder)
        #expect(results.map(\.messages) == [3])
    }

    /// A file that appears under the final name while the export runs is never replaced.
    @Test func aNameTakenMeanwhileIsNeverOverwritten() throws {
        let test = try TestArchive()
        defer { test.remove() }
        _ = try Importer(archive: test.archive).importMessage(test.raw(Data("Subject: x\r\n\r\nbody\r\n".utf8), uid: 1))
        let url = test.location.root.appendingPathComponent("taken.mbox")
        #expect(throws: MboxExportError.destinationExists(url.path)) {
            try MboxExport.export(test.archive, account: test.account.id, to: url, progress: nil) {
                try? Data("someone else's".utf8).write(to: url)
            }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "someone else's")
    }
}
