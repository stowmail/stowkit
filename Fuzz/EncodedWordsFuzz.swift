import Foundation
import StowCore

// libFuzzer target for RFC 2047 encoded words (A-02, security sweep 1), as a
// header value, a display name and a MIME parameter. Built by scripts/fuzz.sh
// words, never by Package.swift.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafeRawPointer?, _ count: Int) -> CInt {
    let raw = start.map { Data(bytes: $0, count: count) } ?? Data()
    let text = String(decoding: raw, as: UTF8.self)
    _ = EncodedWords.decode(text)
    _ = AddressListParser.parse(text)
    _ = ContentField.parse("attachment; filename=\"\(text)\"")
    return 0
}
