import Foundation
import StowCore

// libFuzzer target for the search box (security sweep 1, R-02): whatever a
// person or an MCP client types becomes an FTS5 expression. Built by
// scripts/fuzz.sh query, never by Package.swift.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafeRawPointer?, _ count: Int) -> CInt {
    let raw = start.map { Data(bytes: $0, count: count) } ?? Data()
    let text = String(decoding: raw, as: UTF8.self)
    let query = QueryParser.parse(text)
    _ = FTSExpression.build(query.text)
    return 0
}
