import Foundation

/// The header parser shared by storage and the rules engine (D-017).
///
/// Reads the header block of a raw message (everything before the first blank
/// line; a header-only input is fine too), unfolds continuation lines, keeps
/// every field in order, and fills the typed properties of `MessageHeaders`.
///
/// It never crashes and never throws on malformed input. Problems become
/// entries in `warnings`, which name the problem and the header but never
/// contain header values, so they are safe to log.
public struct HeaderParser: HeaderParsing {
    /// Header blocks longer than this are cut off with a warning, so a hostile
    /// message cannot make the parser hold an unbounded amount of text.
    public static let maximumHeaderBytes = 1 << 20

    /// Headers whose addresses mark where the message was delivered, used to spot "user in BCC only".
    static let deliveredToFields = ["Delivered-To", "X-Original-To", "Envelope-To", "X-Envelope-To", "X-Delivered-To"]

    public init() {}

    public func parseHeaders(_ raw: Data) -> MessageHeaders {
        var warnings: [String] = []
        let block = Self.splitFields(raw, warnings: &warnings)
        return headers(from: block.fields, warnings: warnings)
    }

    /// Fills `MessageHeaders` from fields already split by `splitFields`, for
    /// example the headers of a message forwarded as an attachment. `warnings`
    /// are carried over and added to.
    public func headers(from fields: [HeaderField], warnings existing: [String] = []) -> MessageHeaders {
        var warnings = existing
        var headers = MessageHeaders(fields: fields)

        func addresses(_ name: String) -> [EmailAddress] {
            var result: [EmailAddress] = []
            for value in headers.values(named: name) {
                let parsed = AddressListParser.parse(value)
                if parsed.hadProblem { warnings.append("malformed address list in \(name)") }
                result += parsed.addresses
            }
            return result
        }

        func decodeWords(_ value: String, field: String) -> String {
            let decoded = EncodedWords.decode(value)
            if decoded.hadProblem { warnings.append("undecodable encoded word in \(field)") }
            return decoded.text
        }

        headers.from = addresses("From")
        if headers.from.isEmpty { warnings.append("missing or empty From") }
        headers.sender = addresses("Sender").first
        headers.replyTo = addresses("Reply-To")
        headers.to = addresses("To")
        headers.cc = addresses("Cc")
        headers.bcc = addresses("Bcc")

        var seen = Set<String>()
        for name in Self.deliveredToFields {
            for address in addresses(name) where seen.insert(address.normalised).inserted {
                headers.deliveredTo.append(address)
            }
        }

        if let subject = headers.value(named: "Subject") {
            headers.subject = decodeWords(subject, field: "Subject").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let dateRaw = headers.value(named: "Date") {
            headers.dateRaw = dateRaw
            if let parsed = MessageDateParser.parse(dateRaw) {
                headers.date = parsed.date
                if parsed.assumedUTC { warnings.append("Date has no known time zone, UTC assumed") }
            } else {
                warnings.append("malformed Date")
            }
        } else {
            warnings.append("missing Date")
        }

        if let messageID = headers.value(named: "Message-ID") {
            headers.messageID = AddressListParser.messageIDs(messageID).first
        }
        if headers.messageID == nil { warnings.append("missing Message-ID") }
        headers.inReplyTo = headers.values(named: "In-Reply-To").flatMap(AddressListParser.messageIDs)
        headers.references = headers.values(named: "References").flatMap(AddressListParser.messageIDs)

        headers.listUnsubscribe = headers.value(named: "List-Unsubscribe")
        headers.listUnsubscribePost = headers.value(named: "List-Unsubscribe-Post")
        headers.listID = headers.value(named: "List-ID")
        headers.precedence = headers.value(named: "Precedence").flatMap(Self.keyword)
        headers.autoSubmitted = headers.value(named: "Auto-Submitted").flatMap(Self.keyword)

        headers.warnings = warnings
        return headers
    }

    /// The leading keyword of a structured value, lowercased, without
    /// parameters or comments: `Auto-Submitted: auto-generated; owner=x` gives "auto-generated".
    static func keyword(_ value: String) -> String? {
        var text = value
        if let semicolon = text.firstIndex(of: ";") { text = String(text[..<semicolon]) }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Header block

    /// The fields of a header block, and where the body starts.
    public struct Block: Sendable, Equatable {
        public var fields: [HeaderField]
        /// Index in the input of the first body byte (the input's end if there is no body).
        public var bodyStart: Int
    }

    /// Splits the header block into unfolded fields. Public so the MIME body
    /// parser in `StowStore` can reuse it for the headers of each part.
    ///
    /// Lines may end in CRLF or a bare LF. The block ends at the first empty
    /// line. Header text is read as UTF-8 (RFC 6532), falling back to
    /// Windows-1252 then ISO-8859-1 for old 8-bit headers, with a warning.
    public static func splitFields(_ raw: Data, warnings: inout [String]) -> Block {
        let bytes = [UInt8](raw)
        return splitFields(bytes, in: 0..<bytes.count, warnings: &warnings)
    }

    /// The same, for the bytes in `range` of a larger buffer (one MIME part of
    /// a message), without copying the rest. `bodyStart` is an index into `bytes`.
    public static func splitFields(_ bytes: [UInt8], in range: Range<Int>, warnings: inout [String]) -> Block {
        var lines: [ArraySlice<UInt8>] = []
        var lineStart = range.lowerBound
        var bodyStart = range.upperBound
        let limit = min(range.upperBound, range.lowerBound + maximumHeaderBytes)
        var i = range.lowerBound
        var foundEnd = false
        while i < limit {
            if bytes[i] == 0x0A {
                var end = i
                if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
                if end == lineStart {
                    bodyStart = i + 1
                    foundEnd = true
                    break
                }
                lines.append(bytes[lineStart..<end])
                lineStart = i + 1
            }
            i += 1
        }
        if !foundEnd {
            if limit < range.upperBound {
                warnings.append("header block truncated at \(maximumHeaderBytes) bytes")
            } else if lineStart < range.upperBound {
                // Input ends without a newline: the last line is still a header.
                var end = range.upperBound
                if bytes[end - 1] == 0x0D { end -= 1 }
                if end > lineStart { lines.append(bytes[lineStart..<end]) }
            }
        }

        // Unfold: a line starting with space or tab continues the previous field.
        var unfolded: [[UInt8]] = []
        for line in lines {
            if let first = line.first, first == 0x20 || first == 0x09 {
                if unfolded.isEmpty {
                    warnings.append("continuation line before any header")
                } else {
                    unfolded[unfolded.count - 1] += line
                }
            } else {
                unfolded.append(Array(line))
            }
        }

        var fields: [HeaderField] = []
        var reportedEncoding = false
        var reportedNoColon = false
        for line in unfolded {
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else {
                if !reportedNoColon {
                    warnings.append("header line without a colon skipped")
                    reportedNoColon = true
                }
                continue
            }
            let nameBytes = line[..<colon]
            let name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                if !reportedNoColon {
                    warnings.append("header line without a valid name skipped")
                    reportedNoColon = true
                }
                continue
            }
            let valueBytes = line[(colon + 1)...]
            let value: String
            if let text = String(bytes: valueBytes, encoding: .utf8) {
                value = text
            } else {
                value = Charset.bestEffort(Data(valueBytes))
                if !reportedEncoding {
                    warnings.append("8-bit header bytes that are not UTF-8")
                    reportedEncoding = true
                }
            }
            fields.append(HeaderField(name: name, value: value.trimmingCharacters(in: .whitespaces)))
        }
        return Block(fields: fields, bodyStart: bodyStart)
    }
}
