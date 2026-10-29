import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// Performance checks from the Phase 1B QA checklist. Slow, so they run only with
/// `STOW_BENCH=1`, in a release build:
///
///     STOW_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter Benchmarks
///
/// Optional: `STOW_BENCH_MESSAGES` (default 100000) for the scale test.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["STOW_BENCH"] == "1"))
struct Benchmarks {
    static let account = AccountID(rawValue: "00000000-0000-4000-8000-00000000be9c")
    /// Fixed keys derived from a label, for a kept benchmark archive of synthetic mail only.
    static let syntheticKeys = ArchiveKeys(
        databaseKey: SymmetricKey(data: SHA256.hash(data: Data("stow synthetic benchmark db".utf8))),
        fileKey: SymmetricKey(data: SHA256.hash(data: Data("stow synthetic benchmark files".utf8))))

    func freshArchive() throws -> (Archive, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-bench-\(UUID().uuidString)")
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        try archive.register(Account(id: Self.account, provider: .gmail, email: "bench@example.com", displayName: "Bench"))
        return (archive, root)
    }

    func timeImport(_ archive: Archive, _ messages: [RawMessage], extractText: Bool = true) async throws -> ImportSummary {
        let summary = try await Importer(archive: archive, extractText: extractText).importAll(from: MemorySource(messages))
        #expect(summary.failed == 0)
        return summary
    }

    // MARK: 100,000 messages: import throughput and search latency

    @Test func scaleImportAndSearch() async throws {
        let count = Int(ProcessInfo.processInfo.environment["STOW_BENCH_MESSAGES"] ?? "") ?? 100_000
        var generator = MessageGenerator(seed: 7)
        let messages = (0..<count).map { generator.message(uid: UInt32($0 + 1), attachment: $0 % 7 == 0 ? .text : nil) }
        // STOW_BENCH_KEEP=<folder> keeps the archive (synthetic mail, test-only keys) and reuses it next run.
        let archive: Archive
        var temporaryRoot: URL?
        defer { if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) } }
        if let keep = ProcessInfo.processInfo.environment["STOW_BENCH_KEEP"] {
            let location = ArchiveLocation(root: URL(fileURLWithPath: keep, isDirectory: true))
            let existed = location.exists
            archive = try Archive.open(location, keys: Self.syntheticKeys)
            try archive.register(Account(id: Self.account, provider: .gmail, email: "bench@example.com", displayName: "Bench"))
            if !existed { print("BENCH import \(count): \(try await timeImport(archive, messages))") }
        } else {
            let (fresh, root) = try freshArchive()
            archive = fresh
            temporaryRoot = root
            print("BENCH import \(count): \(try await timeImport(archive, messages))")
        }

        let searcher = MessageSearcher(archive: archive)
        let queries = [
            generator.commonWord, generator.rareWord, "\(generator.commonWord) \(generator.midWord)",
            "\"\(generator.phrase)\"", String(generator.midWord.prefix(3)) + "*", "from:\(generator.sender)",
            "\(generator.midWord) has:attachment", "\(generator.commonWord) after:2020-01-01 before:2021-01-01",
            "zzzznotaword",
            // D-079: browsing with no text, folder and label filters, with and without text.
            "", "in:inbox", "in:\"\(MessageGenerator.rareLabel)\"", "\(generator.commonWord) in:inbox",
            "\(generator.rareWord) in:inbox", "\(generator.commonWord) in:\"\(MessageGenerator.rareLabel)\"",
            "in:inbox has:attachment after:2020-01-01 before:2021-01-01",
        ]
        func best(_ run: () async throws -> Int) async throws -> (Int, Double) {
            _ = try await run()  // warm the cache once
            var best = Double.infinity
            var result = 0
            for _ in 0..<3 {
                let start = Date()
                result = try await run()
                best = min(best, Date().timeIntervalSince(start))
            }
            return (result, best)
        }
        for query in queries {
            let (hits, searched) = try await best { try await searcher.search(QueryParser.parse(query)).count }
            let (total, counted) = try await best { try await searcher.count(QueryParser.parse(query)) }
            print(String(format: "BENCH search %-40@ %3d hits  %6.1f ms   count %6d  %6.1f ms",
                         "'\(query)'" as NSString, hits, searched * 1000, total, counted * 1000))
            #expect(searched < 1.0, "\(query)")
            #expect(counted < 1.0, "count \(query)")
        }
        let longest = try await archive.database.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM messages WHERE thread_key = (SELECT thread_key FROM messages GROUP BY thread_key ORDER BY count(*) DESC LIMIT 1) LIMIT 1")
        }
        if let longest {
            let (size, took) = try await best { try await searcher.thread(of: longest)?.totalCount ?? 0 }
            print(String(format: "BENCH thread of %d messages  %6.1f ms", size, took * 1000))
            let (folders, listed) = try await best { try await searcher.folders(accounts: []).count }
            print(String(format: "BENCH folders %d  %6.1f ms", folders, listed * 1000))
            #expect(took < 0.1)
        }
        // R5 (D-403): From token suggestions, no extra index. One letter matches every sender here: the worst case.
        for prefix in [String(generator.sender.prefix(1)), generator.sender] {
            let (found, took) = try await best { try await searcher.senderSuggestions(prefix: prefix, accounts: [], limit: 10).count }
            print(String(format: "BENCH senders %-40@ %2d  %6.1f ms", "'\(prefix)'" as NSString, found, took * 1000))
            #expect(took < 0.25, "senders \(prefix)")
        }
        let stats = try ArchiveStats.collect(archive)
        print("BENCH archive: database \(stats.databaseBytes / 1_048_576) MB, raw stored \(stats.rawStoredBytes / 1_048_576) MB")
    }

    // MARK: Inline extraction overhead

    @Test func inlineExtractionOverhead() async throws {
        var generator = MessageGenerator(seed: 11)
        // A realistic share of attachments: one message in five has a PDF with a text layer, each unique.
        let messages = (0..<5000).map { generator.message(uid: UInt32($0 + 1), attachment: $0 % 5 == 0 ? .pdf : nil) }
        var with = Double.infinity, without = Double.infinity
        for _ in 0..<2 {
            for extract in [true, false] {
                let (archive, root) = try freshArchive()
                let summary = try await timeImport(archive, messages, extractText: extract)
                try? FileManager.default.removeItem(at: root)
                if extract { with = min(with, summary.seconds) } else { without = min(without, summary.seconds) }
            }
        }
        let overhead = (with - without) / without
        print(String(format: "BENCH extraction: with %.2f s, without %.2f s, overhead %.1f%%", with, without, overhead * 100))
        #expect(overhead < 0.10)
    }

    // MARK: OCR alongside import

    @Test func ocrDoesNotHurtImport() async throws {
        var generator = MessageGenerator(seed: 13)
        let scans = (0..<40).map { generator.message(uid: UInt32(1_000_000 + $0), attachment: .scan) }
        let messages = (0..<5000).map { generator.message(uid: UInt32($0 + 1), attachment: $0 % 7 == 0 ? .text : nil) }

        // Baseline: import alone.
        let (quiet, quietRoot) = try freshArchive()
        let baseline = try await timeImport(quiet, messages)
        try? FileManager.default.removeItem(at: quietRoot)

        // Same import while the OCR queue is busy.
        let (busy, busyRoot) = try freshArchive()
        defer { try? FileManager.default.removeItem(at: busyRoot) }
        _ = try await timeImport(busy, scans)
        let queue = OCRQueue(archive: busy)
        #expect(try queue.status().pending == scans.count)
        let ocr = Task { try await queue.run() }
        let during = try await timeImport(busy, messages)
        let processedDuring = try queue.status().done

        // At background priority OCR yields to a busy CPU (D-207), so it may do little during the
        // import. Prove the queue was live: once import stops, it must make progress on its own.
        let idleStart = Date()
        while try queue.status().done <= processedDuring, Date().timeIntervalSince(idleStart) < 120 {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let firstIdleItem = Date().timeIntervalSince(idleStart)
        ocr.cancel()
        _ = try? await ocr.value

        let slowdown = (during.seconds - baseline.seconds) / baseline.seconds
        print(String(format: "BENCH OCR: import alone %.2f s, with OCR queue running %.2f s (%.1f%%); %d OCR items done during import, next item %.1f s after import ended",
                     baseline.seconds, during.seconds, slowdown * 100, processedDuring, firstIdleItem))
        #expect(try queue.status().done > processedDuring)
        #expect(slowdown < 0.10)
    }

    // MARK: Flushing stored files (A-05, L-5)

    /// A first sync of 10,000 messages, one in three with an attachment, about one
    /// attachment in five shared with an earlier message. Run on the code before and
    /// after a change to how files are flushed; `STOW_BENCH_RUNS` (default 3) runs each.
    @Test func firstSyncWithAttachments() async throws {
        var generator = MessageGenerator(seed: 21)
        var messages = (0..<10_000).map { generator.message(uid: UInt32($0 + 1), attachment: $0 % 3 == 0 ? .text : nil) }
        // Every fifth message with an attachment repeats an earlier one's under a new
        // Message-ID, so the attachment is already stored and reuse is measured too.
        for index in stride(from: 15, to: messages.count, by: 15) {
            let earlier = messages[index - 15]
            let text = String(decoding: earlier.bytes, as: UTF8.self)
                .replacingOccurrences(of: "Message-ID: <gen-\(earlier.key.uid)@", with: "Message-ID: <dup-\(index)@")
            let bytes = Data(text.utf8)
            messages[index] = RawMessage(key: messages[index].key, labels: [], internalDate: earlier.internalDate,
                                         size: bytes.count, bytes: bytes)
        }
        let runs = Int(ProcessInfo.processInfo.environment["STOW_BENCH_RUNS"] ?? "3") ?? 3
        var times: [Double] = []
        for _ in 0..<runs {
            let (archive, root) = try freshArchive()
            let summary = try await timeImport(archive, messages, extractText: false)
            times.append(summary.seconds)
            try? FileManager.default.removeItem(at: root)
        }
        print(String(format: "BENCH first sync with attachments: %@ s", times.map { String(format: "%.2f", $0) }.joined(separator: ", ")))
    }

    // MARK: Removing mail (A-11)

    /// Removes 10,000 messages (one in three with an attachment) in the usual
    /// batches of 200. Run before and after a change to how removal commits.
    @Test func removeTenThousand() async throws {
        var generator = MessageGenerator(seed: 33)
        let messages = (0..<10_000).map { generator.message(uid: UInt32($0 + 1), attachment: $0 % 3 == 0 ? .text : nil) }
        let (archive, root) = try freshArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await timeImport(archive, messages, extractText: false)
        let ids = try await archive.database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM messages ORDER BY id") }
        let start = Date()
        let result = try ArchiveRemoval(archive: archive).remove(ids, reason: "bench")
        print(String(format: "BENCH remove 10,000: %.2f s (%d messages, %d files)", Date().timeIntervalSince(start), result.messages, result.filesDeleted))
    }

    // MARK: MCP queries alongside import (Phase 3 QA)

    /// Imports into an archive that already holds mail, alone and then while a
    /// second, read-only connection makes the calls `stowmail mcp` makes
    /// (search, count, thread, message with body): paced like an assistant
    /// answering questions (a round every 100 ms), and flat out.
    @Test func mcpQueriesDoNotSlowImport() async throws {
        var generator = MessageGenerator(seed: 17)
        let base = (0..<5000).map { generator.message(uid: UInt32($0 + 1), attachment: $0 % 7 == 0 ? .text : nil) }
        var batches: [[RawMessage]] = []
        for round in 1...3 {
            let first = 100_000 * round
            batches.append((0..<5000).map { (n: Int) -> RawMessage in
                generator.message(uid: UInt32(first + n), attachment: n % 7 == 0 ? .text : nil)
            })
        }
        let word = generator.commonWord
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        let archive = try Archive.open(ArchiveLocation(root: root), keys: keys)
        try archive.register(Account(id: Self.account, provider: .gmail, email: "bench@example.com", displayName: "Bench"))
        _ = try await timeImport(archive, base)

        let reader = try EncryptedDatabase.open(at: archive.location.databaseURL, key: keys.databaseKeyData, readOnly: true)
        func queries(pause: UInt64) -> Task<Int, Never> {
            Task.detached {
                let searcher = MessageSearcher(database: reader)
                let messages = MessageReader(database: reader)
                var rounds = 0
                while !Task.isCancelled {
                    let query = SearchQuery(text: word, limit: 20)
                    if let hits = try? await searcher.search(query), let first = hits.first {
                        _ = try? await searcher.count(query)
                        _ = try? await searcher.thread(of: first.messageID)
                        _ = try? await messages.message(first.messageID, bodyLimit: 20_000)
                    }
                    rounds += 1
                    if pause > 0 { try? await Task.sleep(nanoseconds: pause) }
                }
                return rounds
            }
        }

        let alone = try await timeImport(archive, batches[0])
        let pacedTask = queries(pause: 100_000_000)
        let paced = try await timeImport(archive, batches[1])
        pacedTask.cancel()
        let pacedRounds = await pacedTask.value
        let busyTask = queries(pause: 0)
        let busy = try await timeImport(archive, batches[2])
        busyTask.cancel()
        let busyRounds = await busyTask.value

        let pacedSlowdown = (paced.seconds - alone.seconds) / alone.seconds
        let busySlowdown = (busy.seconds - alone.seconds) / alone.seconds
        print(String(format: "BENCH MCP: import of 5,000 alone %.2f s; with paced queries %.2f s (%+.1f%%, %d rounds); flat out %.2f s (%+.1f%%, %d rounds)",
                     alone.seconds, paced.seconds, pacedSlowdown * 100, pacedRounds, busy.seconds, busySlowdown * 100, busyRounds))
        #expect(pacedSlowdown < 0.10)
    }
}

/// Deterministic synthetic mail: Zipf-like word frequencies, a few thousand senders, ten years of dates.
struct MessageGenerator {
    enum Attachment { case text, pdf, scan }

    var rng: SeededRandom
    let words: [String]
    let senders: [String]
    static let textPDF: Data = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/eml")
        return Self.attachment(in: file, prefix: "06-")
    }()
    static let scannedPDF: Data = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/eml")
        return Self.attachment(in: file, prefix: "08-")
    }()

    init(seed: UInt64) {
        rng = SeededRandom(seed: seed)
        let syllables = ["ka", "lo", "mi", "ren", "tor", "sa", "vel", "qui", "dan", "pe", "rho", "bex", "nu", "gal", "fir", "osh"]
        var vocabulary: [String] = []
        var local = SeededRandom(seed: 99)
        while vocabulary.count < 20_000 {
            let length = Int(local.next() % 3) + 2
            let word = (0..<length).map { _ in syllables[Int(local.next() % UInt64(syllables.count))] }.joined()
            vocabulary.append(word + (vocabulary.count > 3000 ? String(vocabulary.count) : ""))
        }
        words = vocabulary
        senders = (0..<3000).map { "person\($0)@domain\($0 % 300).example.com" }
    }

    var commonWord: String { words[0] }
    var midWord: String { words[200] }
    var rareWord: String { words[15_000] }
    var phrase: String { "\(words[1]) \(words[2])" }
    var sender: String { senders[42] }
    static let rareLabel = "Project X"

    mutating func word() -> String {
        // Zipf-like: small indexes are far more common.
        let u = Double(rng.next() % 1_000_000) / 1_000_000
        return words[min(words.count - 1, Int(pow(u, 4) * Double(words.count)))]
    }

    mutating func sentence(_ count: Int) -> String {
        (0..<count).map { _ in word() }.joined(separator: " ")
    }

    mutating func message(uid: UInt32, attachment: Attachment?) -> RawMessage {
        let from = senders[Int(pow(Double(rng.next() % 1000) / 1000, 2) * Double(senders.count))]
        let to = senders[Int(rng.next() % UInt64(senders.count))]
        let date = Date(timeIntervalSince1970: 1_420_070_400 + Double(rng.next() % 315_360_000))
        let subject = sentence(Int(rng.next() % 6) + 3)
        let body = (0..<(Int(rng.next() % 8) + 1)).map { _ in sentence(Int(rng.next() % 50) + 10) }.joined(separator: "\r\n\r\n")
        let dateHeader = Self.rfc5322(date)
        var text = """
            From: \(from)\r\nTo: \(to)\r\nSubject: \(subject)\r\nDate: \(dateHeader)\r\nMessage-ID: <gen-\(uid)@bench.example.com>\r\nMIME-Version: 1.0\r\n
            """
        if let attachment {
            let boundary = "b\(uid)"
            let (name, type, content): (String, String, Data) = switch attachment {
            case .text: ("notes-\(uid).txt", "text/plain", Data(sentence(200).utf8))
            case .pdf: ("report-\(uid).pdf", "application/pdf", Self.textPDF + Data("\n%unique \(uid)\n".utf8))
            case .scan: ("scan-\(uid).pdf", "application/pdf", Self.scannedPDF + Data("\n%unique \(uid)\n".utf8))
            }
            text += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n--\(boundary)\r\n"
            text += "Content-Type: \(type); name=\"\(name)\"\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            text += content.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            text += "\r\n--\(boundary)--\r\n"
        } else {
            text += "Content-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n"
        }
        let bytes = Data(text.utf8)
        // About a fifth of the mail in the Inbox, one in a hundred under a user label; threads of up to 40 (D-079).
        var labels: [String] = []
        if uid % 5 == 0 { labels.append("\\Inbox") }
        if uid % 100 == 0 { labels.append(Self.rareLabel) }
        return RawMessage(key: RawMessageKey(accountID: Benchmarks.account, folder: "[Gmail]/All Mail", uidValidity: 1, uid: uid),
                          labels: labels, gmailThreadID: UInt64(uid / 40 + 1), internalDate: date, size: bytes.count, bytes: bytes)
    }

    static func rfc5322(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    static func attachment(in directory: URL, prefix: String) -> Data {
        let file = try! FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix(prefix) }!
        let parsed = MIMEParser().parse(try! Data(contentsOf: directory.appendingPathComponent(file)))
        return parsed.attachments[0].data
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// An in-memory `RawMessageSource`.
struct MemorySource: RawMessageSource {
    let messages: [RawMessageKey: RawMessage]

    init(_ messages: [RawMessage]) {
        self.messages = Dictionary(messages.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func listKeys() async throws -> [RawMessageKey] { messages.keys.sorted() }

    func read(_ key: RawMessageKey) async throws -> RawMessage {
        guard let message = messages[key] else { throw CocoaError(.fileNoSuchFile) }
        return message
    }
}

/// Timing experiments on a kept benchmark archive (`STOW_BENCH_KEEP`). Prints only.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["STOW_BENCH_EXPLORE"] != nil))
struct SearchExploration {
    func time(_ archive: Archive, _ label: String, _ sql: String, _ arguments: StatementArguments = []) throws {
        var best = Double.infinity
        var rows = 0
        for _ in 0..<3 {
            let start = Date()
            rows = try archive.database.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments).count }
            best = min(best, Date().timeIntervalSince(start))
        }
        print(String(format: "EXPLORE %-28@ %6d rows %8.1f ms", label as NSString, rows, best * 1000))
    }

    @Test func variants() throws {
        let keep = try #require(ProcessInfo.processInfo.environment["STOW_BENCH_KEEP"])
        let archive = try Archive.open(ArchiveLocation(root: URL(fileURLWithPath: keep)), keys: Benchmarks.syntheticKeys)
        let word = "\"torbexquitor\""
        func run(_ phase: String) throws {
            try time(archive, "\(phase) count", "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH ?", [word])
            try time(archive, "\(phase) rowids", "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?", [word])
            try time(archive, "\(phase) rank", "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rank LIMIT 50", [word])
            try time(archive, "\(phase) rowid desc", "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rowid DESC LIMIT 50", [word])
            try time(archive, "\(phase) prefix rank", "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rank LIMIT 50", ["\"dan\"*"])
            try time(archive, "\(phase) subject only", "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rank LIMIT 50", ["{subject} : \(word)"])
        }
        try run("before")
        let ids = try archive.database.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rank LIMIT 50", arguments: [word])
        }
        let list = ids.map(String.init).joined(separator: ",")
        try time(archive, "snippet IN", "SELECT snippet(messages_fts, -1, '[', ']', '', 16) FROM messages_fts WHERE messages_fts MATCH ? AND rowid IN (\(list))", [word])
        var best = Double.infinity
        for _ in 0..<3 {
            let start = Date()
            try archive.database.read { db in
                let statement = try db.cachedStatement(sql: "SELECT snippet(messages_fts, -1, '[', ']', '', 16), highlight(messages_fts, 4, char(1), char(2)) FROM messages_fts WHERE messages_fts MATCH ? AND rowid = ?")
                for id in ids { _ = try Row.fetchOne(statement, arguments: [word, id]) }
            }
            best = min(best, Date().timeIntervalSince(start))
        }
        print(String(format: "EXPLORE snippet per row %8.1f ms", best * 1000))
        try time(archive, "rank as score, bound", "SELECT rowid AS id, rank AS score FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rank LIMIT ? OFFSET ?", ["(\(word))", 50, 0])
        try time(archive, "rank, literal limit", "SELECT rowid AS id, rank AS score FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rank LIMIT 50", ["(\(word))"])
        try time(archive, "bm25 fn", "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? ORDER BY bm25(messages_fts, 10.0, 6.0, 2.0, 1.0, 3.0, 2.0, 1.0) LIMIT 50", [word])
        let bm = "bm25(messages_fts, 10.0, 6.0, 2.0, 1.0, 3.0, 2.0, 1.0)"
        let range: StatementArguments = [word, 1_577_836_800, 1_609_459_200]
        try time(archive, "filter join bm25", "SELECT m.id FROM messages_fts f JOIN messages m ON m.id = f.rowid WHERE messages_fts MATCH ? AND m.internal_date >= ? AND m.internal_date < ? ORDER BY \(bm) LIMIT 50", range)
        try time(archive, "filter cte", "WITH f AS MATERIALIZED (SELECT rowid AS id, \(bm) AS score FROM messages_fts WHERE messages_fts MATCH ?) SELECT m.id FROM f JOIN messages m ON m.id = f.id WHERE m.internal_date >= ? AND m.internal_date < ? ORDER BY f.score LIMIT 50", range)
        try time(archive, "filter rowid in", "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? AND rowid IN (SELECT id FROM messages WHERE internal_date >= ? AND internal_date < ?) ORDER BY \(bm) LIMIT 50", range)
        try time(archive, "has:att rowid in", "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? AND rowid IN (SELECT id FROM messages WHERE has_attachments = 1) ORDER BY \(bm) LIMIT 50", ["\"dannu\""])
        try time(archive, "has:att cte", "WITH f AS MATERIALIZED (SELECT rowid AS id, \(bm) AS score FROM messages_fts WHERE messages_fts MATCH ?) SELECT m.id FROM f JOIN messages m ON m.id = f.id WHERE m.has_attachments = 1 ORDER BY f.score LIMIT 50", ["\"dannu\""])
        for query in ["torbexquitor", "dan*"] {
            var best = Double.infinity
            for _ in 0..<3 {
                let start = Date()
                _ = try archive.database.read { db in try MessageSearcher(archive: archive).search(db, QueryParser.parse(query)) }
                best = min(best, Date().timeIntervalSince(start))
            }
            print(String(format: "EXPLORE searcher %@ %8.1f ms", query, best * 1000))
        }
        if ProcessInfo.processInfo.environment["STOW_BENCH_OPTIMIZE"] != nil {
            let start = Date()
            try archive.database.write { db in try db.execute(sql: "INSERT INTO messages_fts (messages_fts) VALUES ('optimize')") }
            print(String(format: "EXPLORE optimize took %.1f s", Date().timeIntervalSince(start)))
            try run("after")
        }
    }
}
