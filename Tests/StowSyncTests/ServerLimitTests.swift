import Foundation
import NIOCore
import NIOIMAP
import Testing
@testable import StowSync

/// Security review M-4 and M-5: numbers a server sends are bounded before use.
@Suite struct ServerLimitTests {
    @Test func hugeSizesAndLiteralLengthsAreBounded() throws {
        var assembler = FetchAssembler()
        try assembler.consume(.fetch(.startUID(UID(rawValue: 7))))
        try assembler.consume(.fetch(.simpleAttribute(.rfc822Size(Int.max))))
        // Reserving this much memory up front used to trap.
        try assembler.consume(.fetch(.streamingBegin(kind: .body(section: .complete, offset: nil), byteCount: Int.max)))
        try assembler.consume(.fetch(.streamingBytes(ByteBuffer(string: "Subject: hi\r\n\r\nbody\r\n"))))
        try assembler.consume(.fetch(.streamingEnd))
        try assembler.consume(.fetch(.finish))
        let message = try #require(assembler.finished.first)
        #expect(message.size == FetchAssembler.maximumReportedSize)
        // Sums of bounded sizes cannot overflow.
        #expect(FetchAssembler.maximumReportedSize.multipliedReportingOverflow(by: 1_000_000).overflow == false)
        #expect(IMAPConnection.bodySizeLimit >= 150 << 20)
    }
}
