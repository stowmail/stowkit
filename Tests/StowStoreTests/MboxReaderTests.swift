import Foundation
import Testing
@testable import StowStore

@Suite struct MboxReaderTests {
    static func readAll(_ file: some Sequence<UInt8>, variant: MboxVariant = .mboxrd, step: Int = .max, chunkBytes: Int = 1_048_576,
                        maximumLineBytes: Int = 65_536, maximumMessageBytes: Int = MboxLimits.defaultMaximumMessageBytes)
        throws -> (messages: [MboxMessage], counts: MboxReadCounts) {
        var reader = MboxReader(MboxBytes(file, step: step), variant: variant, chunkBytes: chunkBytes,
                                maximumLineBytes: maximumLineBytes, maximumMessageBytes: maximumMessageBytes)
        var messages: [MboxMessage] = []
        while let message = try reader.next() { messages.append(message) }
        return (messages, reader.counts)
    }

    static func mbox(_ text: String) -> Data { Data(text.utf8) }

    @Test func takeoutMessagesComeBackByteForByte() throws {
        let messages = SyntheticTakeout.messages(count: 40)
        let file = SyntheticTakeout.mbox(messages)
        let (read, counts) = try Self.readAll(file)
        #expect(read.map(\.bytes) == messages.map(\.stored))
        #expect(counts.messages == 40)
        #expect(counts.withCRLF == 40)
        #expect(counts.fromLinesKept == 0)
        #expect(counts.linesUnquoted == 80)
        #expect(counts.cutShort == 0)
        #expect(counts.bytesRead == Int64(file.count))
        // Offsets point at each From line, and each message ends where the next begins.
        for (index, message) in read.enumerated() {
            #expect(file[Int(message.offset)..<Int(message.offset + 5)] == Data("From ".utf8))
            #expect(message.endOffset == (index + 1 < read.count ? read[index + 1].offset : Int64(file.count)))
            #expect(message.size == message.bytes.count)
        }
        #expect(MboxSeparator.date(read[0].separator) == messages[0].date)
    }

    @Test func howTheFileIsCutIntoReadsChangesNothing() throws {
        let file = SyntheticTakeout.mbox(SyntheticTakeout.messages(count: 9))
        let expected = try Self.readAll(file)
        for step in [1, 2, 3, 7, 64, 1000, 4096] {
            for chunk in [1, 5, 300, 8192] {
                let got = try Self.readAll(file, step: step, chunkBytes: chunk, maximumLineBytes: 1100)
                #expect(got.messages == expected.messages, "step \(step), chunk \(chunk)")
                #expect(got.counts == expected.counts, "step \(step), chunk \(chunk)")
            }
        }
    }

    @Test func stowsOwnExportReadsBack() throws {
        // MboxExport (D-042) writes mboxrd; reading it gives back every message
        // that ends in a line break, quoting and all.
        let originals = [
            "Subject: a\n\nFrom the top.\n>From one.\n>>From two.\n\n",
            "Subject: b\r\n\r\nCR LF body\r\n>From x\r\n",
            "Subject: c\n\nno blank line at the end\n",
        ].map { Data($0.utf8) }
        var file = Data()
        for message in originals { file.append(MboxExport.entry(message, date: Date(timeIntervalSince1970: 1_761_211_620))) }
        let (read, counts) = try Self.readAll(file)
        #expect(read.map(\.bytes) == originals)
        #expect(counts.linesUnquoted == 4)
        #expect(MboxSeparator.date(read[0].separator) == Date(timeIntervalSince1970: 1_761_211_620))
    }

    @Test func mboxoTakesOffOnlyOneLevel() throws {
        let file = Self.mbox("From a Thu Oct 23 09:27:00 2026\n\n>From one\n>>From two\n\n")
        #expect(try Self.readAll(file, variant: .mboxo).messages[0].bytes == Data("\nFrom one\n>>From two\n".utf8))
        #expect(try Self.readAll(file, variant: .mboxrd).messages[0].bytes == Data("\nFrom one\n>From two\n".utf8))
    }

    @Test func fromLinesThatStartNoMessageAreKept() throws {
        let file = Self.mbox("""
            From a Thu Oct 23 09:27:00 2026
            Subject: one

            From the desk of nobody
            text
            From b Thu Oct 23 09:28:00 2026
            more

            From c Thu Oct 23 09:29:00 2026
            Subject: two

            """)
        let (read, counts) = try Self.readAll(file)
        #expect(read.count == 2)
        #expect(read[0].bytes == Data("Subject: one\n\nFrom the desk of nobody\ntext\nFrom b Thu Oct 23 09:28:00 2026\nmore\n".utf8))
        #expect(read[1].bytes == Data("Subject: two\n".utf8))
        #expect(counts.fromLinesKept == 2)
        #expect(counts.separatorsWithoutBlankLine == 1)
    }

    @Test func aFileCutShortIsCounted() throws {
        let file = Self.mbox("From a Thu Oct 23 09:27:00 2026\nSubject: one\n\nbody\n\nFrom b Thu Oct 23 09:28:00 2026\nSubject: tw")
        let (read, counts) = try Self.readAll(file)
        #expect(read.map(\.problem) == [nil, .cutShort])
        #expect(read[1].bytes == Data("Subject: tw".utf8))
        #expect(counts.cutShort == 1)
    }

    @Test func nulBytesAndCRLFAreKeptAndCounted() throws {
        var file = Self.mbox("From a Thu Oct 23 09:27:00 2026\r\nSubject: x\r\n\r\nnul ")
        file.append(0)
        file.append(Data(" here\r\n\r\n".utf8))
        let (read, counts) = try Self.readAll(file)
        var expected = Data("Subject: x\r\n\r\nnul ".utf8)
        expected.append(0)
        expected.append(Data(" here\r\n".utf8))
        #expect(read[0].bytes == expected)
        #expect(read[0].containsNUL && read[0].usesCRLF)
        #expect(counts.withNUL == 1 && counts.withCRLF == 1)
    }

    @Test func notAnMboxIsRefusedAndAnEmptyFileHasNothing() throws {
        #expect(throws: MboxReadError.notAnMbox) { try Self.readAll(Self.mbox("Subject: hello\n\nFrom a Thu Oct 23 09:27:00 2026\n")) }
        #expect(throws: MboxReadError.notAnMbox) { try Self.readAll(Self.mbox("From nobody in particular\n")) }
        #expect(try Self.readAll(Data()).messages.isEmpty)
        let (read, counts) = try Self.readAll(Self.mbox("\n\r\nFrom a Thu Oct 23 09:27:00 2026\nx\n"))
        #expect(read.map(\.bytes) == [Data("x\n".utf8)])
        #expect(counts.bytesBeforeFirstMessage == 3)
    }

    @Test func emptyMessagesAreCounted() throws {
        let (read, counts) = try Self.readAll(Self.mbox("From a Thu Oct 23 09:27:00 2026\n\nFrom b Thu Oct 23 09:27:00 2026\nx\n"))
        #expect(read.map(\.size) == [0, 2])
        #expect(counts.empty == 1)
    }

    @Test func tooLargeIsReadPastWithoutKeepingIt() throws {
        let big = String(repeating: "0123456789\n", count: 300)
        let file = Self.mbox("From a Thu Oct 23 09:27:00 2026\n\(big)\nFrom b Thu Oct 23 09:28:00 2026\nsmall\n")
        let (read, counts) = try Self.readAll(file, chunkBytes: 64, maximumLineBytes: 1100, maximumMessageBytes: 1000)
        #expect(read[0].problem == .tooLarge)
        #expect(read[0].bytes.isEmpty)
        #expect(read[0].size == big.utf8.count)
        #expect(read[1].bytes == Data("small\n".utf8))
        #expect(counts.tooLarge == 1)
    }

    @Test func longLinesPassThroughInPieces() throws {
        let long = String(repeating: "x", count: 10_000)
        let file = Self.mbox("From a Thu Oct 23 09:27:00 2026\n>From \(long)\n\(long)\n\nFrom b Thu Oct 23 09:28:00 2026\nend\n")
        let (read, _) = try Self.readAll(file, chunkBytes: 100, maximumLineBytes: 1100)
        #expect(read.map(\.bytes) == [Data("From \(long)\n\(long)\n".utf8), Data("end\n".utf8)])
    }

    @Test func resumesAtAnOffsetAndRefusesOneThatIsNotAMessage() throws {
        let messages = SyntheticTakeout.messages(count: 6)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stow-mbox-\(UUID().uuidString).mbox")
        try SyntheticTakeout.mbox(messages).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var reader = MboxReader(try MboxFile(url: url), chunkBytes: 100)
        let first = try #require(try reader.next())
        let second = try #require(try reader.next())
        var resumed = MboxReader(try MboxFile(url: url, offset: second.endOffset), offset: second.endOffset)
        var rest: [Data] = []
        while let message = try resumed.next() { rest.append(message.bytes) }
        #expect([first.bytes, second.bytes] + rest == messages.map(\.stored))
        #expect(rest.count == 4)

        var wrong = MboxReader(try MboxFile(url: url, offset: second.endOffset + 1), offset: second.endOffset + 1)
        #expect(throws: MboxReadError.notAtMessageStart(second.endOffset + 1)) { try wrong.next() }
    }

    @Test func fromLineShapes() {
        #expect(MboxSeparator.isShaped(ArraySlice("MAILER-DAEMON Thu Oct 23 09:27:00 2026".utf8)))
        #expect(MboxSeparator.isShaped(ArraySlice("1780000000000000000@xxx Mon Sep 18 10:12:13 +0000 2023".utf8)))
        #expect(MboxSeparator.isShaped(ArraySlice("- Sat Jan  3 01:05 1996".utf8)))
        #expect(!MboxSeparator.isShaped(ArraySlice("the desk of nobody".utf8)))
        #expect(!MboxSeparator.isShaped(ArraySlice(" leading space 09:27 2026".utf8)))
        #expect(!MboxSeparator.isShaped(ArraySlice("me at 9:5 in 2026".utf8)))
        let takeout = Data("From 1@xxx Mon Sep 18 10:12:13 +0100 2023".utf8)
        #expect(MboxSeparator.date(takeout) == Date(timeIntervalSince1970: 1_695_028_333))
        #expect(MboxSeparator.date(Data("From a b c d e f".utf8)) == nil)
    }
}

/// Security checklist: no network connection is opened by any import code
/// path (D-109). The mbox files and the CLI command must not name a network API.
@Suite struct MboxImportOpensNoConnectionTests {
    @Test func importSourcesNameNoNetworkAPI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Sources/StowStore/Import/MboxReader.swift", "Sources/StowStore/Import/MboxScan.swift",
                     "Sources/StowStore/Import/MboxImport.swift", "Sources/StowStore/Import/FileImport.swift",
                     "Sources/stowmail/ImportCommands.swift"]
        let banned = ["import Network", "import NIO", "import StowSync", "URLSession", "NWConnection", "CFStream", "socket(",
                      "connect(", "getaddrinfo", "IMAPSession", "OAuthClient", "TokenProvider", "SyncEngine", "Scheduler"]
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for word in banned { #expect(!text.contains(word), "\(file) names \(word)") }
        }
    }
}
