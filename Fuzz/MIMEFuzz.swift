import CryptoKit
import Foundation
import StowCore

// libFuzzer target for everything that reads bytes a stranger wrote (Phase 4).
// Built by scripts/fuzz.sh mime, never by Package.swift, so nothing here can
// reach a release build.
//
// Each input is treated as a raw message, as sync hands it to the importer:
// it is parsed, its attachments are checked against the input, and a skeleton
// is built and must expand to the input byte for byte (D-029). The same bytes
// also go to the skeleton reader and the .docx zip reader (D-204), since both
// take attacker-shaped input too. A crash, an out-of-bounds read (the build
// uses AddressSanitizer), a hang or a broken invariant is a finding.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafeRawPointer?, _ count: Int) -> CInt {
    let raw = start.map { Data(bytes: $0, count: count) } ?? Data()
    let parsed = MIMEParser().parse(raw)

    for attachment in parsed.attachments {
        let range = attachment.encodedRange
        precondition(range.lowerBound >= 0 && range.upperBound <= raw.count, "attachment range outside the message")
        _ = ZipReader(attachment.data).entry(named: "word/document.xml")
    }
    _ = parsed.status
    _ = parsed.bodyText

    let hashOf: (Data) -> Data = { Data(SHA256.hash(data: $0)) }
    if let result = RawCompaction.skeleton(raw, parsed: parsed, hashOf: hashOf) {
        let lookup = Dictionary(parsed.attachments.map { (hashOf($0.data).hex, $0.data) },
                                uniquingKeysWith: { first, _ in first })
        let expanded = try? RawCompaction.expand(result.skeleton, attachment: { lookup[$0] })
        precondition(expanded == raw, "skeleton does not expand to the original")
        _ = try? RawCompaction.headerBlock(ofSkeleton: result.skeleton)
    }

    _ = try? RawCompaction.expand(raw, attachment: { _ in Data(count: 3) })
    _ = try? RawCompaction.headerBlock(ofSkeleton: raw)
    _ = ZipReader(raw).entry(named: "word/document.xml")
    _ = HeaderParser().parseHeaders(raw)
    return 0
}
