import Foundation
import NIOCore
import NIOIMAPCore

// libFuzzer target for IMAP response assembly (A-13, security sweep 1 R-02):
// bytes a server sends, parsed by swift-nio-imap's ResponseParser as the
// connection does, then fed to FetchAssembler. Built by scripts/fuzz.sh
// imap, never by Package.swift. A response kept for a UID that was not
// asked for, or more bytes kept than the limit allows, is a finding.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafeRawPointer?, _ count: Int) -> CInt {
    var buffer = ByteBuffer(bytes: UnsafeRawBufferPointer(start: start, count: start == nil ? 0 : count))
    var parser = ResponseParser(options: ResponseParser.Options(bufferLimit: 64 << 10, bodySizeLimit: 256 << 20))
    let wanted: Set<UInt32> = [1, 2, 3]
    let limit = 256 << 10
    var assembler = FetchAssembler(wanted: .uids(wanted), byteLimit: limit)
    parsing: while buffer.readableBytes > 0 {
        let next: ResponseOrContinuationRequest?
        do {
            next = try parser.parseResponseStream(buffer: &buffer)
        } catch {
            break
        }
        guard let next else { break }
        guard case .response(let response) = next else { continue }
        do {
            try assembler.consume(response)
        } catch {
            break parsing
        }
    }
    precondition(assembler.finished.allSatisfy { $0.uid.map(wanted.contains) ?? false }, "kept a response that was not asked for")
    let kept = assembler.finished.reduce(0) { $0 + ($1.body?.count ?? 0) + ($1.headerFields?.count ?? 0) }
    precondition(kept <= limit, "kept more bytes than the limit")
    return 0
}
