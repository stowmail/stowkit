import Foundation
import StowEngine
import Testing

/// A-14: the line printed for an error reaching `main` is scrubbed and on one line.
@Suite struct TopLevelErrorTests {
    struct ServerSaid: Error, CustomStringConvertible {
        var description: String
    }

    @Test func tokensAddressesAndLineBreaksAreRemoved() {
        let error = ServerSaid(description: "NO [AUTHENTICATIONFAILED] for sam@example.com\r\nError: forged Bearer abcdefghijklmnopqrstuvwxyz0123456789ABCD ya29.a0AfH6SMBexampletoken\u{1B}]52;c;aGk=\u{7}")
        let line = TopLevelError.line(for: error)
        #expect(line.hasPrefix("Error: NO [AUTHENTICATIONFAILED] for addr:"))
        for leak in ["sam@example.com", "abcdefghijklmnopqrstuvwxyz0123456789ABCD", "ya29.", "\r", "\n", "\u{1B}", "\u{7}"] {
            #expect(!line.contains(leak), "line contains \(leak.debugDescription)")
        }
        #expect(line.contains(#"\r\nError: forged"#))
        #expect(line.contains(#"\u{1B}]52"#))
    }

    @Test func localizedErrorsUseTheirDescription() {
        struct Described: LocalizedError { var errorDescription: String? { "Disk full\nat /Volumes/x" } }
        #expect(TopLevelError.line(for: Described()) == #"Error: Disk full\nat /Volumes/x"#)
    }

    @Test func nsErrorsAreScrubbed() {
        let error = NSError(domain: "GRDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "near \"pat@example.org\"\nsyntax error"])
        let line = TopLevelError.line(for: error)
        #expect(!line.contains("pat@example.org") && !line.contains("\n"))
    }
}
