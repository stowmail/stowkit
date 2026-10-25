import CryptoKit
import Foundation
import GRDB
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// A page of hits in mail with long bodies and large attachment text (D-417). On Toby's real
/// archive a 74-hit page took 650 ms: `highlight()` returned every column whole, attachment text
/// included. 1,178 ms here before the fix, 120 ms after (release, M1 Pro Max). Slow to set up, so
/// it runs with the other benchmarks: `STOW_BENCH=1 swift test -c release --filter LargeTextSearchBenchmark`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STOW_BENCH"] == "1"))
struct LargeTextSearchBenchmark {
    @Test func pageOfHitsInLargeTexts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive.open(ArchiveLocation(root: root), keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        let account = AccountID(rawValue: "00000000-0000-4000-8000-0000000000aa")
        try archive.register(Account(id: account, provider: .gmail, email: "p@example.com", displayName: "P"))
        let words = "accounts lease van invoice quote photos lunch ticket receipt bill energy order draft review studio project meeting garden holiday".split(separator: " ")
        var rng = SystemRandomNumberGenerator()
        func text(_ n: Int) -> String { (0..<n).map { _ in String(words.randomElement(using: &rng)!) }.joined(separator: " ") }
        let importer = Importer(archive: archive)
        for i in 0..<300 {
            let marker = i < 74 ? " kitchen " : " "
            let body = text(8_000) + marker + text(2_000)
            let attachment = Data((text(60_000) + marker).utf8).base64EncodedString(options: .lineLength76Characters)
            let raw = "From: a\(i)@example.org\r\nSubject: S \(i)\r\nMessage-ID: <p\(i)@example.org>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b\"\r\n\r\n--b\r\nContent-Type: text/plain\r\n\r\n\(body)\r\n--b\r\nContent-Type: text/plain; name=\"notes.txt\"\r\nContent-Disposition: attachment; filename=\"notes.txt\"\r\nContent-Transfer-Encoding: base64\r\n\r\n\(attachment)\r\n--b--\r\n"
            _ = try importer.importMessage(RawMessage(key: RawMessageKey(accountID: account, folder: "INBOX", uidValidity: 1, uid: UInt32(i + 1)), internalDate: Date(), size: raw.utf8.count, bytes: Data(raw.utf8)))
        }
        let searcher = MessageSearcher(archive: archive)
        func ms(_ block: () async throws -> Void) async rethrows -> Double {
            let start = ContinuousClock.now; try await block(); let d = ContinuousClock.now - start
            return Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
        }
        var query = QueryParser.parse("kitchen")
        query.limit = 100
        _ = try await searcher.search(query)
        var best = Double.infinity
        for _ in 0..<3 { best = min(best, try await ms { _ = try await searcher.search(query) }) }
        let hits = try await searcher.search(query)
        print("benchmark: 74-hit page in large texts: \(best) ms")
        #expect(hits.count == 74)
        #expect(hits.allSatisfy { $0.snippet.contains("[kitchen]") })
        #expect(best < 250, "a page of hits in large texts took \(best) ms")
    }
}
