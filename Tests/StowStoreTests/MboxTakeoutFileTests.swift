import Foundation
import Testing
@testable import StowStore

/// Checks a real Google Takeout file kept outside the repo (CLAUDE.md: no real
/// email in fixtures). Opt in: `STOW_TAKEOUT_MBOX=<path> swift test --filter
/// MboxTakeoutFileTests`. Puts the file back together from what the reader
/// returns and compares it with the original, so every byte the reader keeps
/// or drops is accounted for (D-559). Prints counts only, never content.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STOW_TAKEOUT_MBOX"] != nil))
struct MboxTakeoutFileTests {
    @Test func takeoutFileRebuildsByteForByte() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STOW_TAKEOUT_MBOX"] ?? "")
        let original = try Data(contentsOf: url)
        var reader = MboxReader(try MboxFile(url: url))
        var rebuilt = Data()
        var messages = 0
        while let message = try reader.next() {
            #expect(message.problem == nil)
            #expect(message.offset == Int64(rebuilt.count))
            let lineEnd = message.usesCRLF ? Data("\r\n".utf8) : Data("\n".utf8)
            rebuilt.append(message.separator)
            rebuilt.append(lineEnd)
            rebuilt.append(Self.mboxrdQuoted(message.bytes))
            rebuilt.append(lineEnd)
            #expect(message.endOffset == Int64(rebuilt.count))
            messages += 1
        }
        let counts = reader.counts
        #expect(rebuilt.count == original.count)
        #expect(rebuilt == original)
        #expect(counts.separatorsWithoutBlankLine == 0)
        #expect(counts.bytesBeforeFirstMessage == 0)
        print("Takeout file: \(messages) messages, \(original.count) bytes, \(counts.withCRLF) with CR LF, "
            + "\(counts.fromLinesKept) From lines kept in bodies, \(counts.linesUnquoted) unquoted")
    }

    /// The inverse of the reader's mboxrd unquoting: one more `>` in front of
    /// any line that is `From ` after zero or more `>`.
    static func mboxrdQuoted(_ bytes: Data) -> Data {
        var out = Data()
        var lineStart = true
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if lineStart {
                var probe = index
                while probe < bytes.endIndex, bytes[probe] == UInt8(ascii: ">") { probe += 1 }
                if bytes[probe...].starts(with: Data("From ".utf8)) { out.append(UInt8(ascii: ">")) }
            }
            out.append(bytes[index])
            lineStart = bytes[index] == UInt8(ascii: "\n")
            index += 1
        }
        return out
    }
}
