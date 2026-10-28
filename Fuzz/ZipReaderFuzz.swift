import Foundation

// libFuzzer target for the .docx zip reader (D-204, security sweep 1). Built
// by scripts/fuzz.sh zip, never by Package.swift.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafeRawPointer?, _ count: Int) -> CInt {
    let raw = start.map { Data(bytes: $0, count: count) } ?? Data()
    _ = ZipReader(raw).entry(named: "word/document.xml")
    return 0
}
