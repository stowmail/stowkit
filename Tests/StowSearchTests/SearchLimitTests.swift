import CryptoKit
import Foundation
import StowCore
import StowSecrets
import Testing
@testable import StowSearch
@testable import StowStore

/// A-18: free text has limits, so one query cannot make every search do
/// unbounded work (the CLI, MCP and the app all use `FTSExpression`).
@Suite struct SearchLimitTests {
    static func terms(in expression: String) -> Int {
        expression.components(separatedBy: "\"").count / 2
    }

    @Test func aHugeQueryIsCutToTheByteLimit() throws {
        let words = (0..<2_000).map { "w\($0)" }.joined(separator: " ") // about 12 KB
        let expression = try #require(FTSExpression.build(words))
        #expect(expression.utf8.count < 2_048)
        #expect(Self.terms(in: expression) <= 32)
    }

    @Test func atMost32TermsAreSearched() throws {
        let words = (0..<500).map { "term\($0)" }.joined(separator: " ")
        let expression = try #require(FTSExpression.build(words))
        #expect(Self.terms(in: expression) == 32)
        #expect(expression.contains("\"term31\"") && !expression.contains("\"term32\""))
        // Exclusions count too.
        let mixed = (0..<40).map { $0 % 2 == 0 ? "a\($0)" : "-b\($0)" }.joined(separator: " ")
        #expect(Self.terms(in: try #require(FTSExpression.build(mixed))) == 32)
    }

    @Test func aOneCharacterPrefixIsSearchedAsAWord() throws {
        #expect(FTSExpression.build("a*") == "\"a\"")
        #expect(FTSExpression.build("\"a\"*") == "\"a\"")
        #expect(FTSExpression.build("ab*") == "\"ab\"*")
        #expect(FTSExpression.build("é*") == "\"é\"")
    }

    @Test func theQuerySaysWhatWasCut() {
        #expect(QueryParser.parse("invoice acme from:alex").limitsApplied.isEmpty)
        #expect(QueryParser.parse("invoice acme").limitsApplied.notice == nil)
        let many = QueryParser.parse((0..<40).map { "w\($0)" }.joined(separator: " "))
        #expect(many.limitsApplied == .tooManyWords)
        #expect(many.limitsApplied.notice == "Searched for the first 32 words only.")
        #expect(QueryParser.parse("a* invoice").limitsApplied == .shortPrefix)
        #expect(QueryParser.parse(String(repeating: "x", count: 2_000)).limitsApplied == .tooLong)
        // Filters made outside the parser (MCP) are capped too.
        #expect(SearchQuery(text: "", from: (0..<40).map { "f\($0)" }.joined(separator: " ")).limitsApplied == .tooManyWords)
        // A cut never splits a character.
        let cut = SearchLimits.apply(String(repeating: "日", count: 500)).text
        #expect(cut.utf8.count <= 1_024 && cut.allSatisfy { $0 == "日" })
    }

    @Test func ordinaryQueriesAreUnchanged() {
        #expect(FTSExpression.build("invoice acme") == "\"invoice\" AND \"acme\"")
        #expect(FTSExpression.build("inv* OR bill -spam") == "((\"inv\"* OR \"bill\")) NOT (\"spam\")")
    }
}

/// Measures a worst-case query on a synthetic archive. Prints its figures.
@Suite(.serialized) struct SearchLimitTimingTests {
    @Test func aWorstCaseQueryFinishesQuickly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-limits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        try archive.register(Account(id: Benchmarks.account, provider: .gmail, email: "limits@example.com", displayName: "Limits"))
        var generator = MessageGenerator(seed: 18)
        let messages = (0..<3_000).map { generator.message(uid: UInt32($0 + 1), attachment: nil) }
        let started = Date()
        let summary = try await Importer(archive: archive, extractText: false).importAll(from: MemorySource(messages))
        #expect(summary.failed == 0 && summary.imported == 3_000)
        print("LIMITS import 3000: \(String(format: "%.1f", Date().timeIntervalSince(started))) s")

        let searcher = MessageSearcher(archive: archive)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        func prefixes(_ n: Int, length: Int) -> [String] {
            (0..<n).map { i in String((0..<length).map { letters[(i / Int(pow(26.0, Double($0)))) % 26] }) + "*" }
        }
        var shapes: [(String, String)] = []
        for n in [32, 100, 500] {
            shapes.append(("AND of \(n) 1-letter prefixes", prefixes(n, length: 1).joined(separator: " ")))
            shapes.append(("AND of \(n) 2-letter prefixes", prefixes(n, length: 2).joined(separator: " ")))
            shapes.append(("OR of \(n) 1-letter prefixes", prefixes(n, length: 1).joined(separator: " OR ")))
            shapes.append(("OR of \(n) 2-letter prefixes", prefixes(n, length: 2).joined(separator: " OR ")))
        }
        var elapsed = 0.0
        for (name, text) in shapes {
            let query = SearchQuery(text: text, limit: 50)
            let begin = Date()
            do {
                let hits = try await searcher.search(query)
                let count = try await searcher.count(query)
                let time = Date().timeIntervalSince(begin)
                elapsed = max(elapsed, time)
                print("LIMITS \(name): \(String(format: "%.3f", time)) s, \(hits.count) hits of \(count)")
            } catch {
                print("LIMITS \(name): ERROR \(String(describing: error).prefix(60))")
            }
        }
        // The new worst case, an OR of 32 two-letter prefixes, took 0.21 s here in a debug
        // build with the Mac loaded (load average 8); before the limits, an OR of 32 one-letter
        // prefixes took 1.1 s and 100 or more terms failed (FTS5 parser stack overflow).
        #expect(elapsed < 1.5)
    }
}
