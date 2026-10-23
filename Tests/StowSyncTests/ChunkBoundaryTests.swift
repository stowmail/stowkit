import Foundation
import NIOCore
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import StowSync

/// D-120: message bytes must survive every way a reply can be split into reads.
@Suite struct ChunkBoundaryTests {
    /// A FETCH reply carrying `body` as a literal, plus the tagged completion.
    static func reply(_ body: [UInt8], uid: Int = 2361) -> [UInt8] {
        Array("* 7 FETCH (UID \(uid) RFC822.SIZE \(body.count) BODY[] {\(body.count)}\r\n".utf8) + body
            + Array(")\r\nS4 OK FETCH completed\r\n".utf8)
    }

    /// A body with CRLFs, a bare CR, a bare LF, ending in CRLF (as in the real case).
    static let body = Array("Received: from x\r\nSubject: t\r\n\r\nline\rcr\nlf\r\n".utf8)

    /// Runs `chunks` through the parser exactly as IMAPClientHandler does
    /// (bytes accumulate until a response parses), optionally behind the guard,
    /// and returns the literal's bytes.
    static func parse(_ chunks: [[UInt8]], guarded: Bool) throws -> [UInt8] {
        var parser = ResponseParser()
        var holder = TrailingCRHolder()
        var pending = ByteBuffer()
        var body: [UInt8] = []
        func drain() throws {
            while pending.readableBytes > 0, let response = try parser.parseResponseStream(buffer: &pending) {
                if case .response(.fetch(.streamingBytes(let bytes))) = response { body += bytes.readableBytesView }
            }
        }
        for chunk in chunks {
            var incoming = ByteBuffer(bytes: chunk)
            if guarded { incoming = holder.process(incoming) }
            pending.writeBuffer(&incoming)
            try drain()
        }
        if guarded, var rest = holder.flush() { pending.writeBuffer(&rest); try drain() }
        return body
    }

    /// Documents the upstream bug, so an upgrade that fixes it is noticed.
    @Test func unguardedParserCorruptsALiteralSplitAfterItsHeaderCR() throws {
        let whole = Self.reply(Self.body)
        let cut = whole.firstIndex(of: UInt8(ascii: "\r"))! + 1 // just after "{n}\r"
        let corrupted = try Self.parse([Array(whole[..<cut]), Array(whole[cut...])], guarded: false)
        #expect(corrupted == [UInt8(ascii: "\n")] + Self.body.dropLast()) // exactly what Microsoft 365 produced
    }

    @Test func everySingleSplitIsByteExact() throws {
        let whole = Self.reply(Self.body)
        for cut in 1..<whole.count {
            let parsed = try Self.parse([Array(whole[..<cut]), Array(whole[cut...])], guarded: true)
            #expect(parsed == Self.body, "split at \(cut)")
        }
    }

    /// Every pair of split points, so the final byte alone, CR and LF in
    /// separate reads, and one-byte reads all occur.
    @Test func everyPairOfSplitsIsByteExact() throws {
        let whole = Self.reply(Self.body)
        for first in 1..<whole.count {
            for second in (first + 1)..<whole.count {
                let chunks = [Array(whole[..<first]), Array(whole[first..<second]), Array(whole[second...])]
                #expect(try Self.parse(chunks, guarded: true) == Self.body, "splits at \(first), \(second)")
            }
        }
    }

    @Test func oneByteReadsAreByteExact() throws {
        let whole = Self.reply(Self.body)
        #expect(try Self.parse(whole.map { [$0] }, guarded: true) == Self.body)
    }

    @Test func holderNeverChangesTheByteStream() {
        var holder = TrailingCRHolder()
        let pieces: [[UInt8]] = [[13], [13], [10, 13], [], [65, 13, 13], [10], [13]]
        var out: [UInt8] = []
        for piece in pieces {
            let passed = holder.process(ByteBuffer(bytes: piece))
            #expect(passed.readableBytesView.last != 13)
            out += passed.readableBytesView
        }
        out += holder.flush()?.readableBytesView ?? []
        #expect(out == pieces.flatMap { $0 })
    }
}

/// Cut points around every literal in a FETCH reply: just after the header's
/// CR, between the last body byte and the rest, and between the body's final CR and LF.
func literalBoundaryCuts(_ reply: Data) -> [Int] {
    let bytes = [UInt8](reply)
    var cuts: [Int] = []
    var index = 0
    while index < bytes.count {
        // Find "BODY[] {n}\r\n"
        guard bytes[index] == UInt8(ascii: "{"), index >= 7,
              String(decoding: bytes[(index - 7)..<index], as: UTF8.self) == "BODY[] ",
              let close = bytes[index...].firstIndex(of: UInt8(ascii: "}")),
              let length = Int(String(decoding: bytes[(index + 1)..<close], as: UTF8.self))
        else { index += 1; continue }
        let start = close + 3
        cuts += [close + 2, start + length - 2, start + length - 1, start + length]
        index = start + length
    }
    return cuts
}

@Suite struct ChunkBoundarySyncTests {
    /// The real failure, end to end through the connection: every message's
    /// literal is split after its header CR, before its final byte and between
    /// its final CR and LF. Every stored message must equal the original.
    @Test func splitRepliesAreStoredByteForByte() async throws {
        let fixtures = try Fixtures.all()
        let server = gmailServer(fixtures)
        server.splitFetchReply = { literalBoundaryCuts($0) }
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 4)))
        #expect(report.notDownloaded == 0)
        let keys = try await harness.store.listKeys().sorted { $0.uid < $1.uid }
        #expect(keys.count == fixtures.count)
        for (index, key) in keys.enumerated() {
            #expect(try await harness.store.read(key).bytes == fixtures[index].bytes, "\(fixtures[index].name)")
        }
    }

    /// The same, through the D-118 retry paths (sub-batches, then one UID at a time).
    @Test func splitRepliesOnTheRetryPathsAreByteForByte() async throws {
        let fixtures = try Fixtures.small()
        let server = gmailServer(fixtures)
        server.splitFetchReply = { literalBoundaryCuts($0) }
        server.refusals = [5: 1, 9: 2, 13: 2]
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(report.notDownloaded == 0)
        #expect(harness.sleeps.delays == [2, 5])
        let keys = try await harness.store.listKeys().sorted { $0.uid < $1.uid }
        #expect(keys.count == fixtures.count)
        for (index, key) in keys.enumerated() {
            #expect(try await harness.store.read(key).bytes == fixtures[index].bytes, "\(fixtures[index].name)")
        }
    }
}

/// D-120: Exchange's RFC822.SIZE is an estimate, not the byte count. Sync and
/// verify must work regardless; only the literal's announced length is exact.
@Suite struct InexactSizeTests {
    /// Sizes off in both directions, in listings and fetches alike.
    static let estimate: @Sendable (Int) -> Int = { length in length % 2 == 0 ? length + 37 : max(1, length - 11) }

    @Test func syncStoresExactBytesWhateverRFC822SizeSays() async throws {
        let fixtures = try Fixtures.all()
        let server = gmailServer(fixtures)
        server.reportedSize = Self.estimate
        server.splitFetchReply = { literalBoundaryCuts($0) }
        let harness = try await SyncHarness(server: server)
        defer { harness.cleanUp() }

        let report = try await harness.syncer().run(SyncOptions(batches: BatchPlanner(maxMessages: 6)))
        #expect(report.notDownloaded == 0 && report.outcome == .complete)
        #expect(harness.sleeps.delays.isEmpty) // nothing was treated as missing
        let keys = try await harness.store.listKeys().sorted { $0.uid < $1.uid }
        #expect(keys.count == fixtures.count)
        for (index, key) in keys.enumerated() {
            let stored = try await harness.store.read(key)
            #expect(stored.bytes == fixtures[index].bytes)
            #expect(stored.size == Self.estimate(fixtures[index].bytes.count)) // kept as metadata, as reported
        }

        let verify = try await StoreVerifier(
            account: harness.account,
            openSession: { [port = Int(harness.port)] in
                let session = try await IMAPSession.connect(to: .plaintextLoopback(port: port))
                try await session.authenticate(user: "sam@example.com", accessToken: "good-token")
                return session
            },
            source: harness.store,
            budget: ByteBudget(limit: nil, fileURL: nil)
        ).run(sample: nil)
        #expect(verify.isClean && verify.identical == fixtures.count && verify.notCompared.isEmpty)
    }
}
