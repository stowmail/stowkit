import Foundation
@testable import StowMCP
import Testing

/// A-16: `stowmail mcp log` prints what an assistant sent; none of it may
/// reach the terminal as an escape sequence, a line break or a bidi control.
@Suite struct AuditLogPrintingTests {
    static let hostile: [String] = [
        "\u{1B}[2K",                 // erase line
        "\u{1B}]52;c;aGVsbG8=\u{7}", // OSC 52: write the clipboard
        "\u{1B}]52;c;aGVsbG8=\u{1B}\\",
        "\u{9B}31m",                 // C1 CSI
        "\r", "\n", "\r\n",
        "\u{202E}", "\u{2066}", "\u{061C}",
    ]

    @Test(arguments: hostile)
    func everyFieldIsPrintedSafely(sequence: String) {
        let entry = MCPAuditEntry(client: "client\(sequence)x", tool: "search\(sequence)", arguments: ["q\(sequence)": "v\(sequence)y", "limit": "5"],
                                  accounts: [], results: 3, error: false)
        let line = entry.printedLine(time: "2026-10-29 22:00")
        for scalar in line.unicodeScalars {
            #expect(!(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)), "control U+\(String(scalar.value, radix: 16)) printed")
            #expect(!ArchiveTools.bidiControls.contains(scalar.value), "bidi control printed")
        }
        #expect(line.hasPrefix("2026-10-29 22:00  client"))
        #expect(line.contains("limit=5") && line.hasSuffix("-> 3"))
    }
}
