import CryptoKit
import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// Engine items for Phase 5 step 5a: OCR pending per account (R10), one email as
/// an .eml file (R12, D-419) and removing chosen emails (R14, D-422).
@Suite(.serialized) struct ScreensEngineTests {
    // MARK: R10

    @Test func ocrPendingIsCountedPerAccount() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let other = Account(id: AccountID(rawValue: "00000000-0000-4000-8000-000000000002"), provider: .gmail,
                            email: "jo@example.com", displayName: "Jo")
        try test.archive.register(other)
        _ = try Importer(archive: test.archive).importMessage(test.raw(try Fixtures.data("08-"), uid: 1))
        let statuses = try ArchiveStatus.collect(test.archive)
        #expect(statuses.first { $0.account.account.id == test.account.id }?.ocrPending == 1)
        #expect(statuses.first { $0.account.account.id == other.id }?.ocrPending == 0)
        #expect(try ArchiveStats.collect(test.archive).ocrPending == 1)
    }

    // MARK: R12

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stow-eml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func savedFileIsTheStoredOriginalByteForByte() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let out = try folder()
        defer { try? FileManager.default.removeItem(at: out) }
        // A message with an attachment, stored as a skeleton: the file must be the rebuilt original.
        guard case .imported(let id) = try Importer(archive: test.archive).importMessage(test.raw(try Fixtures.data("06-"), uid: 1))
        else { Issue.record("not imported"); return }
        let file = try await EmlExport.export(test.archive, message: id, into: out)
        #expect(try Data(contentsOf: file) == test.archive.rawMessage(id))
        #expect(file.pathExtension == "eml")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // A second save never replaces the first: it gets " 2".
        let second = try await EmlExport.export(test.archive, message: id, into: out)
        #expect(second.lastPathComponent == SafeFile.numbered(file.lastPathComponent, 2))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
                    == [file.lastPathComponent, second.lastPathComponent].sorted())
    }

    @Test func aFailedWriteLeavesNoFileUnderTheFinalName() async throws {
        let out = try folder()
        defer { try? FileManager.default.removeItem(at: out) }
        struct Broken: Error {}
        await #expect(throws: SafeFileError.writeFailed(out.path)) {
            try await SafeFile.write(into: out, name: "Invoice.eml") { handle in
                try handle.write(contentsOf: Data("half a message".utf8))
                throw Broken()
            }
        }
        // Neither the final name nor the temporary one is left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func aRemovedEmailCannotBeSaved() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let out = try folder()
        defer { try? FileManager.default.removeItem(at: out) }
        guard case .imported(let id) = try Importer(archive: test.archive).importMessage(test.raw(try Fixtures.data("01-"), uid: 1))
        else { Issue.record("not imported"); return }
        _ = try ArchiveRemoval(archive: test.archive).remove([id], reason: "chosen")
        await #expect(throws: EmlExportError.notInArchive(id)) { try await EmlExport.export(test.archive, message: id, into: out) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func savingIntoAFileTheUserAgreedToReplace() async throws {
        let out = try folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let target = out.appendingPathComponent("Letter.eml")
        try Data("old".utf8).write(to: target)
        _ = try await SafeFile.write(to: target, replacing: true) { try $0.write(contentsOf: Data("new".utf8)) }
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        let kept = try await SafeFile.write(to: target, replacing: false) { try $0.write(contentsOf: Data("third".utf8)) }
        #expect(kept.lastPathComponent == "Letter 2.eml")
        #expect(try Data(contentsOf: target) == Data("new".utf8))
    }

    @Test func fileNameFollowsD419() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)  // 9 Oct 2025, UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(EmlFileName.make(date: date, subject: "Invoice 4471: October", sender: EmailAddress(name: "Hartley & Co", address: "a@b.example"),
                                 timeZone: utc) == "2025-10-09 Invoice 4471- October, Hartley & Co.eml")
        #expect(EmlFileName.make(date: date, subject: nil, sender: EmailAddress(address: "a@b.example"), timeZone: utc)
                    == "2025-10-09 No subject, a@b.example.eml")
        #expect(EmlFileName.make(date: date, subject: "../.secret\n\tline", sender: nil, timeZone: utc) == "2025-10-09 -.secret line.eml")
        let long = EmlFileName.make(date: date, subject: String(repeating: "word ", count: 60), sender: nil, timeZone: utc)
        #expect(long.utf8.count <= EmlFileName.maxBytes && long.hasSuffix(".eml"))
        #expect(SafeFile.numbered("Invoice.eml", 3) == "Invoice 3.eml")
        #expect(SafeFile.numbered("README", 2) == "README 2")
    }

    // MARK: R14

    @Test func chosenEmailsAreRemovedProtectedIncludedAndCanBePutBack() async throws {
        let test = try TestArchive()
        defer { test.remove() }
        let store = ArchiveSyncStore(archive: test.archive, importer: Importer(archive: test.archive, classifier: { headers, _ in
            // Stand-in rules: an "invoice" subject is protected.
            (headers.subject ?? "").lowercased().contains("invoice")
                ? StoredRuleResult(suggestion: .keep, score: 0, signals: [StoredRuleResult.protectedMarker])
                : StoredRuleResult(suggestion: .keep, score: 0, signals: [])
        }))
        _ = try await store.beginFolder(test.account.id, folder: "INBOX", uidValidity: 1, exists: 3)
        var ids: [StoredMessageID] = []
        for uid in 1...3 {
            let subject = uid == 2 ? "Invoice 2" : "Note \(uid)"
            let text = "From: Jo <jo@example.org>\r\nSubject: \(subject)\r\nMessage-ID: <n\(uid)@example.org>\r\n\r\nhello\r\n"
            try await store.write(test.raw(Data(text.utf8), uid: UInt32(uid)))
        }
        ids = try await test.archive.database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }
        let removal = ArchiveRemoval(archive: test.archive)
        let plan = try removal.plan(.messages([ids[0], ids[1], 9_999]))
        #expect(plan.messageIDs == [ids[0], ids[1]])
        #expect(plan.protectedIncluded == 1 && plan.protectedLeftOut == 0)
        #expect(plan.senderDomains == 1 && plan.bytes > 0)
        // Another account's scope finds nothing.
        #expect(try removal.plan(.messages(ids), account: AccountID(rawValue: "other")).messageIDs.isEmpty)

        let result = try removal.remove(plan.messageIDs, reason: RemovalSelector.messages(plan.messageIDs).reason)
        #expect(result.messages == 2)
        #expect(try test.count("messages") == 1)
        #expect(try test.count("tombstones", "reason = 'chosen'") == 2)
        // Undo: the tombstones the removal wrote go back in the download queue at their place.
        #expect(Set(result.tombstones) == Set(try removal.tombstones().map(\.id)))
        #expect(try removal.requestRestore(result.tombstones) == (2, 0))
        #expect(try await store.nextDownloads(test.account.id, runID: "r", maxMessages: 10, maxBytes: 100_000).count == 2)
    }

    @Test func chosenIDsAreBoundNotSpliced() throws {
        let test = try TestArchive()
        defer { test.remove() }
        // Many IDs (over SQLite's old 999-variable limit) plan in chunks.
        let plan = try ArchiveRemoval(archive: test.archive).plan(.messages(Array(1...2_500)))
        #expect(plan.messageIDs.isEmpty)
    }
}
