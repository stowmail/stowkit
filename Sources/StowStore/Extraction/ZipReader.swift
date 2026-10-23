import Compression
import Foundation

/// Reads single files out of a zip archive, enough for .docx (D-204).
///
/// Apple has no public zip API, but a zip file is a simple index (the
/// "central directory") plus entries that are either stored as is or
/// compressed with DEFLATE, which Apple's Compression framework decodes
/// (`COMPRESSION_ZLIB` is raw DEFLATE). So this needs no dependency and no
/// shelling out to `/usr/bin/unzip`, which a sandboxed app could not do anyway.
///
/// Defensive by design, since attachments come from strangers: sizes are
/// capped (no zip bombs), ZIP64 and encrypted entries are declined, and any
/// inconsistency returns nil rather than reading out of bounds.
struct ZipReader {
    static let maximumEntrySize = 64 << 20

    let bytes: [UInt8]

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// The uncompressed content of the entry named `name`, or nil.
    func entry(named name: String) -> Data? {
        guard let directory = centralDirectory() else { return nil }
        var offset = directory.offset
        let target = Array(name.utf8)
        for _ in 0..<directory.count {
            guard u32(offset) == 0x0201_4b50,
                  let flags = u16(offset + 8), let method = u16(offset + 10),
                  let compressedSize = u32(offset + 20), let size = u32(offset + 24),
                  let nameLength = u16(offset + 28), let extraLength = u16(offset + 30),
                  let commentLength = u16(offset + 32), let localOffset = u32(offset + 42),
                  offset + 46 + Int(nameLength) <= bytes.count
            else { return nil }
            let entryName = bytes[(offset + 46)..<(offset + 46 + Int(nameLength))]
            if entryName.elementsEqual(target) {
                guard flags & 1 == 0,  // encrypted
                      compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF,  // ZIP64
                      Int(size) <= Self.maximumEntrySize
                else { return nil }
                return read(local: Int(localOffset), method: method, compressedSize: Int(compressedSize), size: Int(size))
            }
            offset += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return nil
    }

    private func read(local: Int, method: UInt16, compressedSize: Int, size: Int) -> Data? {
        guard u32(local) == 0x0403_4b50, let nameLength = u16(local + 26), let extraLength = u16(local + 28) else { return nil }
        let start = local + 30 + Int(nameLength) + Int(extraLength)
        guard start >= 0, start + compressedSize <= bytes.count else { return nil }
        let compressed = bytes[start..<(start + compressedSize)]
        switch method {
        case 0:
            return compressedSize == size ? Data(compressed) : nil
        case 8:
            guard size > 0 else { return Data() }
            var output = [UInt8](repeating: 0, count: size)
            let written = compressed.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    compression_decode_buffer(destination.baseAddress!, size, source.baseAddress!, compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            return written == size ? Data(output) : nil
        default:
            return nil
        }
    }

    /// Finds the end-of-central-directory record in the last 64 KiB.
    private func centralDirectory() -> (offset: Int, count: Int)? {
        guard bytes.count >= 22 else { return nil }
        var position = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while position >= floor {
            if u32(position) == 0x0605_4b50, let count = u16(position + 10), let offset = u32(position + 16) {
                guard offset != 0xFFFF_FFFF, Int(offset) < bytes.count else { return nil }
                return (Int(offset), Int(count))
            }
            position -= 1
        }
        return nil
    }

    private func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
