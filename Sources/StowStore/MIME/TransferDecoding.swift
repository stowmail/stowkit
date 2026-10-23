import Foundation

/// Undoes Content-Transfer-Encoding (RFC 2045 section 6): the step that made
/// binary or 8-bit content safe to send as 7-bit text.
enum TransferDecoding {
    enum Encoding: Equatable {
        case identity  // 7bit, 8bit, binary or not stated
        case base64
        case quotedPrintable
        case unknown

        init(header: String?) {
            switch header?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case nil, "", "7bit", "8bit", "binary": self = .identity
            case "base64": self = .base64
            case "quoted-printable": self = .quotedPrintable
            default: self = .unknown
            }
        }
    }

    /// Decodes `bytes[range]`. Never fails: invalid input decodes as far as it
    /// can, and `hadProblem` says so. Unknown encodings are returned as is.
    static func decode(_ bytes: [UInt8], _ range: Range<Int>, encoding: Encoding) -> (data: Data, hadProblem: Bool) {
        switch encoding {
        case .identity: return (Data(bytes[range]), false)
        case .unknown: return (Data(bytes[range]), true)
        case .base64: return base64(bytes, range)
        case .quotedPrintable: return (quotedPrintable(bytes, range), false)
        }
    }

    private static let base64Table: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, char) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            table[Int(char)] = UInt8(index)
        }
        // URL-safe variants, which some broken mailers emit.
        table[Int(UInt8(ascii: "-"))] = 62
        table[Int(UInt8(ascii: "_"))] = 63
        return table
    }()

    /// Lenient base64: skips line breaks and any character outside the
    /// alphabet, stops at padding, and keeps whole bytes from a short tail.
    static func base64(_ bytes: [UInt8], _ range: Range<Int>) -> (Data, Bool) {
        // Fast path: Foundation's decoder handles well-formed bodies with line breaks.
        if let data = Data(base64Encoded: Data(bytes[range]), options: .ignoreUnknownCharacters) {
            return (data, false)
        }
        return lenientBase64(bytes, range)
    }

    static func lenientBase64(_ bytes: [UInt8], _ range: Range<Int>) -> (Data, Bool) {
        var output = [UInt8]()
        output.reserveCapacity(range.count * 3 / 4)
        var accumulator: UInt32 = 0
        var bits = 0
        var problem = false
        var sawPadding = false
        for index in range {
            let byte = bytes[index]
            if byte == UInt8(ascii: "=") {
                sawPadding = true
                continue
            }
            let value = base64Table[Int(byte)]
            if value == 0xFF {
                if !(byte == 0x0D || byte == 0x0A || byte == 0x20 || byte == 0x09) { problem = true }
                continue
            }
            if sawPadding {
                // Data after padding: usually a second base64 block glued on. Keep decoding.
                problem = true
                sawPadding = false
            }
            accumulator = accumulator << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
            }
        }
        if bits >= 6 { problem = true }  // a dangling sextet cannot be a byte
        return (Data(output), problem)
    }

    /// Quoted-printable: `=XX` is a byte, `=` at line end is a soft break.
    /// Invalid escapes are kept as written (what RFC 2045 recommends).
    static func quotedPrintable(_ bytes: [UInt8], _ range: Range<Int>) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(range.count)
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let byte = bytes[i]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                i += 1
                continue
            }
            // Soft line break: "=" then optional spaces, then CRLF or LF.
            var j = i + 1
            while j < end, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
            if j < end, bytes[j] == 0x0D, j + 1 < end, bytes[j + 1] == 0x0A {
                i = j + 2
                continue
            }
            if j < end, bytes[j] == 0x0A {
                i = j + 1
                continue
            }
            if j == end {
                i = end
                continue
            }
            if i + 2 < end, let high = hex(bytes[i + 1]), let low = hex(bytes[i + 2]) {
                output.append(high << 4 | low)
                i += 3
            } else {
                output.append(byte)
                i += 1
            }
        }
        return Data(output)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
