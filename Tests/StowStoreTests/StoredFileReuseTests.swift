import Foundation
import GRDB
import StowCore
import Testing
@testable import StowStore

/// A-05 and L-5: a stored file is flushed before the rows that use it commit,
/// and a file already at its content address is checked before it is reused.
@Suite(.serialized) struct StoredFileReuseTests {
    enum Damage: CaseIterable, Sendable {
        case truncated, empty, flippedByte

        func apply(to url: URL) throws {
            var bytes = try Data(contentsOf: url)
            switch self {
            case .truncated: bytes = bytes.prefix(bytes.count / 2)
            case .empty: bytes = Data()
            case .flippedByte: bytes[bytes.count - 20] ^= 0x01
            }
            try bytes.write(to: url)
        }
    }

    /// A message with one 3,000-byte attachment, so it is stored as a skeleton
    /// and needs the attachment file to rebuild.
    static func message(_ subject: String, payload: UInt8 = 7) -> Data {
        let body = Data((0..<3000).map { UInt8(truncatingIfNeeded: Int($0) * Int(payload)) })
            .base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data("""
            From: a@example.com\r\nTo: sam@example.com\r\nSubject: \(subject)\r\nMessage-ID: <\(subject)@example.com>\r
            MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="b"\r\n\r\n--b\r\nContent-Type: text/plain\r\n\r\nhello\r\n--b\r
            Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=x.bin\r
            \r\n\(body)\r\n--b--\r\n
            """.utf8)
    }

    static func attachmentContent(payload: UInt8 = 7) -> Data {
        Data((0..<3000).map { UInt8(truncatingIfNeeded: Int($0) * Int(payload)) })
    }

    /// A torn attachment left at its address (a power cut after the rename)
    /// is replaced by the next message carrying it, which then rebuilds.
    @Test(arguments: Damage.allCases) func aDamagedAttachmentIsReplacedNotReused(_ damage: Damage) throws {
        let test = try TestArchive()
        defer { test.remove() }
        let content = Self.attachmentContent()
        let hash = test.archive.attachmentFiles.hash(of: content)
        try test.archive.attachmentFiles.write(content, hash: hash)
        try damage.apply(to: test.archive.attachmentFiles.url(for: hash))

        let raw = Self.message("first")
        guard case .imported(let id) = try Importer(archive: test.archive).importMessage(test.raw(raw, uid: 1)) else {
            Issue.record("should import")
            return
        }
        #expect(try test.count("messages", "raw_state = 'skeleton'") == 1)
        #expect(try test.archive.attachmentFiles.read(hash) == content)
        #expect(try test.archive.rawMessage(id) == raw)
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
    }

    /// A torn raw message file (a crash after the file, before its rows) no
    /// longer stops that message from ever being archived.
    @Test(arguments: Damage.allCases) func aDamagedMessageFileIsReplaced(_ damage: Damage) throws {
        let test = try TestArchive()
        defer { test.remove() }
        let raw = Self.message("second")
        let hash = test.archive.rawFiles.hash(of: raw)
        try test.archive.rawFiles.write(raw, hash: hash)
        try damage.apply(to: test.archive.rawFiles.url(for: hash))

        guard case .imported(let id) = try Importer(archive: test.archive).importMessage(test.raw(raw, uid: 1)) else {
            Issue.record("should import")
            return
        }
        #expect(try test.archive.rawMessage(id) == raw)
        #expect(try ArchiveVerifier(archive: test.archive).run().isClean)
    }

    /// A file that authenticates is reused as it is: same inode, never rewritten.
    @Test func aGoodExistingFileIsReusedUntouched() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let content = Self.attachmentContent()
        let hash = test.archive.attachmentFiles.hash(of: content)
        try test.archive.attachmentFiles.write(content, hash: hash)
        let url = test.archive.attachmentFiles.url(for: hash)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)

        let raw = Self.message("third")
        _ = try Importer(archive: test.archive).importMessage(test.raw(raw, uid: 1))
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(after[.systemFileNumber] as? Int == before[.systemFileNumber] as? Int)
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        #expect(try test.archive.attachmentFiles.write(content, hash: hash).written == false)
    }

    /// Every new file is handed to the drive before its rename and its folder
    /// after, then one barrier, all before the transaction that refers to them commits.
    @Test func newFilesAreFlushedBeforeTheirRowsCommit() throws {
        let test = try TestArchive()
        defer { test.remove() }
        let steps = StepLog()
        let archive = try Archive.open(test.location, keys: test.keys, diskSync: steps.sync)
        _ = try Importer(archive: archive).importMessage(test.raw(Self.message("fourth"), uid: 1))
        let recorded = steps.all
        guard let commit = recorded.firstIndex(of: .commit) else { Issue.record("no commit recorded: \(recorded)"); return }
        let renames = recorded.enumerated().compactMap { index, step -> (Int, String, String)? in
            if case .rename(let from, let to) = step { return (index, from, to) }
            return nil
        }
        #expect(renames.count == 2) // the attachment and the skeleton
        guard let barrier = recorded.lastIndex(of: .barrier) else { Issue.record("no barrier before the commit: \(recorded)"); return }
        #expect(barrier < commit)
        for (index, from, to) in renames {
            #expect(recorded[..<index].contains(.flushFile(from, .handedOver)), "\(to) renamed before it was flushed")
            let folder = URL(fileURLWithPath: to).deletingLastPathComponent().path
            #expect(recorded[index..<barrier].contains(.flushFolder(folder, .handedOver)), "\(to)'s folder not flushed before the barrier")
        }
    }
}

/// Records every `DiskSync` step in order.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [DiskSync.Step] = []
    var all: [DiskSync.Step] { lock.withLock { steps } }
    var sync: DiskSync { DiskSync { step in self.lock.withLock { self.steps.append(step) } } }
}
