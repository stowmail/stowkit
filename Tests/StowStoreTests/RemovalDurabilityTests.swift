import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// A-11: removal makes each batch's commit durable before it deletes a file,
/// so no removed row can come back pointing at a deleted file.
@Suite(.serialized) struct RemovalDurabilityTests {
    /// `count` messages, each with an attachment of its own, imported into `test`.
    static func importMessages(_ count: Int, into archive: Archive, test: TestArchive) throws -> [StoredMessageID] {
        let importer = Importer(archive: archive)
        return try (1...count).map { n in
            let raw = StoredFileReuseTests.message("removal-\(n)", payload: UInt8(truncatingIfNeeded: n))
            guard case .imported(let id) = try importer.importMessage(test.raw(raw, uid: UInt32(n))) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return id
        }
    }

    /// Seam: every unlink comes after a durable commit, and no batch deletes a
    /// file before its own commit is durable.
    @Test func eachBatchIsDurableBeforeItsFilesAreDeleted() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let steps = StepLog()
        let archive = try Archive.open(test.location, keys: test.keys, diskSync: steps.sync)
        let ids = try Self.importMessages(250, into: archive, test: test)
        let before = steps.all.count
        let result = try ArchiveRemoval(archive: archive).remove(ids, reason: "test")
        #expect(result.messages == 250)
        let removal = Array(steps.all.dropFirst(before))
        let unlinks = removal.indices.filter { if case .unlink = removal[$0] { true } else { false } }
        let commits = removal.indices.filter { removal[$0] == .durableCommit }
        #expect(commits.count == 2) // batches of 200 and 50
        #expect(unlinks.count == result.filesDeleted && !unlinks.isEmpty)
        for unlink in unlinks {
            // The newest commit before this unlink is durable, and there is one.
            #expect(commits.contains { $0 < unlink })
        }
        // The second batch's unlinks come after its own commit, not just the first's.
        guard commits.count == 2, let last = unlinks.last else { return }
        #expect(last > commits[1])
        #expect(unlinks.contains { $0 > commits[0] && $0 < commits[1] })
    }

    /// The durable commit really runs with `synchronous = FULL` and `fullfsync`,
    /// and the connection goes back to its settings.
    @Test func durableTransactionsUseAFullSync() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let inside = try test.archive.database.writeWithoutTransaction { db in
            try test.archive.durably(db) {
                (try Int.fetchOne(db, sql: "PRAGMA synchronous"), try Int.fetchOne(db, sql: "PRAGMA fullfsync"))
            }
        }
        #expect(inside.0 == 2 && inside.1 == 1)
        #expect(try test.archive.database.write { try Int.fetchOne($0, sql: "PRAGMA synchronous") } == 1)
    }

    /// The real thing: 500 removed, reopened, verified.
    @Test func removingFiveHundredLeavesAConsistentArchive() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let ids = try Self.importMessages(520, into: test.archive, test: test)
        _ = try ArchiveRemoval(archive: test.archive).remove(Array(ids.prefix(500)), reason: "test")
        try test.archive.database.close()
        let reopened = try Archive.open(test.location, keys: test.keys)
        let report = try ArchiveVerifier(archive: reopened).run()
        #expect(report.isClean)
        #expect(report.messages == 20)
        #expect(report.unusedMessageFiles == 0 && report.unusedAttachmentFiles == 0)
    }
}
