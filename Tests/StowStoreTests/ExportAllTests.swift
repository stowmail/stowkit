import CryptoKit
import Foundation
import StowCore
import StowSecrets
import Testing
@testable import StowStore

/// "Export everything" (D-068, D-406): one mbox per account, in one folder.
struct ExportAllTests {
    final class Fixture: @unchecked Sendable {
        let root: URL
        let archive: Archive
        let work = AccountID(rawValue: "00000000-0000-4000-8000-0000000000a1")
        let home = AccountID(rawValue: "00000000-0000-4000-8000-0000000000a2")
        let empty = AccountID(rawValue: "00000000-0000-4000-8000-0000000000a3")
        private var uid: UInt32 = 0

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-exportall-\(UUID().uuidString)")
            archive = try Archive.open(ArchiveLocation(root: root.appendingPathComponent("archive")),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
            try archive.register(Account(id: work, provider: .microsoft, email: "Sam.Work@Example.com", displayName: "Work"))
            try archive.register(Account(id: home, provider: .gmail, email: "sam/../home@example.net", displayName: "Home"))
            try archive.register(Account(id: empty, provider: .gmail, email: "sam.work@example.com", displayName: "Same address"))
            for (account, count) in [(work, 3), (home, 2)] {
                for _ in 0..<count {
                    uid += 1
                    let text = "From: a@example.org\r\nSubject: m\(uid)\r\n\r\nFrom the start\r\nline \(uid)\r\n"
                    let raw = RawMessage(key: RawMessageKey(accountID: account, folder: "INBOX", uidValidity: 1, uid: uid),
                                         internalDate: Date(timeIntervalSince1970: 1_756_684_800 + Double(uid) * 60),
                                         size: text.utf8.count, bytes: Data(text.utf8))
                    _ = try Importer(archive: archive).importMessage(raw)
                }
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func oneFilePerAccountIdenticalToTheSingleExport() throws {
        let f = try Fixture()
        let folder = f.root.appendingPathComponent("export/everything")
        let results = try MboxExport.exportAll(f.archive, to: folder)
        #expect(results.map(\.file.lastPathComponent) == [
            "sam.work@example.com.mbox", "sam_.._home@example.net.mbox", "sam.work@example.com-2.mbox",
        ])
        #expect(results.map(\.messages) == [3, 2, 0])
        #expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700)
        for result in results {
            #expect((try FileManager.default.attributesOfItem(atPath: result.file.path)[.posixPermissions] as? Int) == 0o600)
            let single = f.root.appendingPathComponent("single-\(result.account.rawValue).mbox")
            try MboxExport.export(f.archive, account: result.account, to: single)
            #expect(try Data(contentsOf: single) == Data(contentsOf: result.file))
        }
    }

    @Test func refusesBeforeWritingAnythingWhenAFileExists() throws {
        let f = try Fixture()
        let folder = f.root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("sam_.._home@example.net.mbox")
        try Data("mine".utf8).write(to: existing)
        #expect(throws: MboxExportError.destinationExists(existing.path)) { try MboxExport.exportAll(f.archive, to: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["sam_.._home@example.net.mbox"])
        #expect(try Data(contentsOf: existing) == Data("mine".utf8))

        let file = f.root.appendingPathComponent("a-file")
        try Data().write(to: file)
        #expect(throws: MboxExportError.notAFolder(file.path)) { try MboxExport.exportAll(f.archive, to: file) }
    }

    @Test func fileNames() {
        #expect(MboxExport.fileName(for: "Sam@Example.com", fallback: "x") == "sam@example.com")
        #expect(MboxExport.fileName(for: "..hidden@example.com", fallback: "x") == "hidden@example.com")
        #expect(MboxExport.fileName(for: "a b:c\\d@example.com", fallback: "x") == "a_b_c_d@example.com")
        #expect(MboxExport.fileName(for: "...", fallback: "id") == "id")
    }
}
