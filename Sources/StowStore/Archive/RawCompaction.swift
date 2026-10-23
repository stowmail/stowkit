import Foundation

public enum RawCompactionError: Error, Equatable {
    case notASkeleton
    case malformedSkeleton
    case attachmentMissing
}

/// Raw message compaction (D-005): a stub, not yet wired to the CLI or the
/// database, with tests proving it is reversible on the fixtures.
///
/// A *skeleton* is the raw message with the encoded bodies of its attachments
/// cut out, plus a small manifest saying where each one went and how to
/// re-encode it from the deduplicated attachment file. Expanding re-encodes
/// each attachment and puts it back, giving the original bytes exactly.
///
/// Only attachments whose re-encoding reproduces the original bytes exactly
/// are cut out (checked at compaction time), and the whole skeleton is expanded
/// and compared with the original before it is returned. So compaction never
/// loses a byte; anything irregular simply stays inline.
///
/// Skeleton layout: `SKL1`, a 4-byte big-endian manifest length, the JSON
/// manifest, then the skeleton bytes.
public enum RawCompaction {
    static let magic = Array("SKL1".utf8)

    struct Cut: Codable, Equatable {
        /// Where in the skeleton bytes the attachment body goes back.
        var offset: Int
        /// Attachment file hash, hex.
        var hash: String
        /// "base64" or "identity".
        var encoding: String
        var lineLength: Int
        var crlf: Bool
        var trailingNewline: Bool
    }

    /// Builds a skeleton, or returns nil if no attachment could be cut out safely.
    /// `hashOf` gives the attachment file hash for decoded content.
    public static func compact(_ raw: Data, parsed: ParsedMessage, hashOf: (Data) -> Data) -> Data? {
        let bytes = [UInt8](raw)
        var cuts: [(range: Range<Int>, cut: Cut)] = []
        for attachment in parsed.attachments.sorted(by: { $0.encodedRange.lowerBound < $1.encodedRange.lowerBound }) {
            let range = attachment.encodedRange
            guard range.count >= 64, cuts.last.map({ $0.range.upperBound <= range.lowerBound }) ?? true else { continue }
            let original = bytes[range]
            let hash = hashOf(attachment.data).map { String(format: "%02x", $0) }.joined()
            var cut: Cut?
            switch attachment.transferEncoding {
            case "base64":
                if let shape = base64Shape(original) {
                    let candidate = Cut(offset: 0, hash: hash, encoding: "base64", lineLength: shape.lineLength,
                                        crlf: shape.crlf, trailingNewline: shape.trailingNewline)
                    if encode(attachment.data, candidate).elementsEqual(original) { cut = candidate }
                }
            case nil, "7bit", "8bit", "binary":
                if attachment.data.elementsEqual(original) {
                    cut = Cut(offset: 0, hash: hash, encoding: "identity", lineLength: 0, crlf: false, trailingNewline: false)
                }
            default:
                break
            }
            if let cut { cuts.append((range, cut)) }
        }
        guard !cuts.isEmpty else { return nil }

        var skeleton: [UInt8] = []
        skeleton.reserveCapacity(bytes.count)
        var position = 0
        var manifest: [Cut] = []
        for (range, cut) in cuts {
            skeleton += bytes[position..<range.lowerBound]
            var placed = cut
            placed.offset = skeleton.count
            manifest.append(placed)
            position = range.upperBound
        }
        skeleton += bytes[position...]

        guard let json = try? JSONEncoder().encode(manifest) else { return nil }
        var output = Data(magic)
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { output.append(contentsOf: $0) }
        output.append(json)
        output.append(contentsOf: skeleton)

        // Prove it: expanding must give the original exactly.
        let lookup = Dictionary(parsed.attachments.map { (hashOf($0.data).map { String(format: "%02x", $0) }.joined(), $0.data) },
                                uniquingKeysWith: { first, _ in first })
        guard let expanded = try? expand(output, attachment: { lookup[$0] }), expanded == raw else { return nil }
        return output
    }

    /// Rebuilds the original raw message from a skeleton, reading attachment
    /// content (by hex hash) from `attachment`.
    public static func expand(_ skeleton: Data, attachment: (String) throws -> Data?) throws -> Data {
        let bytes = [UInt8](skeleton)
        guard bytes.count >= 8, Array(bytes[0..<4]) == magic else { throw RawCompactionError.notASkeleton }
        let length = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        guard 8 + length <= bytes.count,
              let manifest = try? JSONDecoder().decode([Cut].self, from: Data(bytes[8..<(8 + length)]))
        else { throw RawCompactionError.malformedSkeleton }
        let body = bytes[(8 + length)...]
        var output = [UInt8]()
        var position = body.startIndex
        for cut in manifest {
            let at = body.startIndex + cut.offset
            guard at >= position, at <= body.endIndex else { throw RawCompactionError.malformedSkeleton }
            output += body[position..<at]
            guard let content = try attachment(cut.hash) else { throw RawCompactionError.attachmentMissing }
            output += encode(content, cut)
            position = at
        }
        output += body[position...]
        return Data(output)
    }

    /// Expands using the archive's attachment files.
    static func expand(_ skeleton: Data, attachments: EncryptedFileStore) throws -> Data {
        try expand(skeleton) { hex in
            var hash = Data()
            var index = hex.startIndex
            while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) {
                hash.append(byte)
                index = next
            }
            return try attachments.read(hash)
        }
    }

    static func encode(_ content: Data, _ cut: Cut) -> [UInt8] {
        guard cut.encoding == "base64" else { return [UInt8](content) }
        let encoded = Array(content.base64EncodedData())
        let newline: [UInt8] = cut.crlf ? [0x0D, 0x0A] : [0x0A]
        var output: [UInt8] = []
        output.reserveCapacity(encoded.count + encoded.count / max(cut.lineLength, 1) * 2 + 2)
        var start = 0
        while start < encoded.count {
            let end = min(start + cut.lineLength, encoded.count)
            output += encoded[start..<end]
            if end < encoded.count || cut.trailingNewline { output += newline }
            start = end
        }
        return output
    }

    /// Line length, line ending and final newline of a base64 body, if regular.
    static func base64Shape(_ original: ArraySlice<UInt8>) -> (lineLength: Int, crlf: Bool, trailingNewline: Bool)? {
        guard let firstLF = original.firstIndex(of: 0x0A) else {
            return (original.count, false, false)  // one line, no newline
        }
        let crlf = firstLF > original.startIndex && original[firstLF - 1] == 0x0D
        let lineLength = firstLF - original.startIndex - (crlf ? 1 : 0)
        guard lineLength > 0 else { return nil }
        return (lineLength, crlf, original.last == 0x0A)
    }
}
