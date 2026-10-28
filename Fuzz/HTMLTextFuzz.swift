import Foundation

// libFuzzer target for HTML to text (A-01, security sweep 1). Built by
// scripts/fuzz.sh html, never by Package.swift. Run with a large -max_len and
// a short -timeout, so a quadratic path shows up as a slow unit.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafeRawPointer?, _ count: Int) -> CInt {
    let raw = start.map { Data(bytes: $0, count: count) } ?? Data()
    _ = HTMLText.text(fromHTML: String(decoding: raw, as: UTF8.self))
    return 0
}
