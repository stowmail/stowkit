import Foundation
import StowCore

/// One attachment found in a message, decoded.
public struct ParsedAttachment: Sendable {
    /// IMAP-style part number, for example "2" or "2.1", to find it in the raw message again.
    public var partPath: String
    /// Decoded file name (RFC 2047 and RFC 2231). Nil if the message gave none.
    public var filename: String?
    /// What the message declared, lowercased, for example "application/pdf".
    public var declaredMimeType: String
    public var disposition: Disposition
    /// Content-ID without angle brackets, for `cid:` references in HTML.
    public var contentID: String?
    /// The decoded content.
    public var data: Data
    /// Where the encoded body sits in the raw message, and how it was encoded.
    /// Used by raw message compaction (D-005).
    public var encodedRange: Range<Int>
    public var transferEncoding: String?

    public enum Disposition: String, Sendable {
        case attachment
        case inline
    }
}

/// A message after MIME parsing: headers, body text and attachments.
public struct ParsedMessage: Sendable {
    public var headers: MessageHeaders
    /// Every text/plain body part, decoded, joined by blank lines. Nil if none.
    public var textPlain: String?
    /// Every text/html body part, as plain text. Nil if none.
    public var textFromHTML: String?
    public var attachments: [ParsedAttachment]
    /// Header and body warnings together. Fixed phrases, never content.
    public var warnings: [String]

    public enum Status: String, Sendable {
        case ok
        case degraded
        case failed
    }

    public var status: Status {
        if headers.fields.isEmpty { return .failed }
        return warnings.isEmpty ? .ok : .degraded
    }

    /// The best body text for searching: the plain part, else the text of the HTML part.
    public var bodyText: String? { textPlain ?? textFromHTML }
}

/// Parses a complete RFC 5322 message with its MIME structure
/// (RFC 2045 to 2049). Hand-written (D-201): there is no Apple framework for
/// MIME and no maintained, complete Swift package.
///
/// Never crashes. Missing boundaries, unknown encodings, bad charsets and
/// structures nested too deeply degrade to the best reading available and add
/// a warning. Messages forwarded as attachments (`message/rfc822`) are opened:
/// their headers and text join the body, and their attachments are listed with
/// part paths inside the forwarded message.
public struct MIMEParser: Sendable {
    /// Bumped whenever parsing output changes, so stored messages can be re-parsed from their raw copy.
    public static let version = 1
    static let maximumDepth = 20
    static let maximumParts = 2000

    let headerParser = HeaderParser()

    public init() {}

    public func parse(_ raw: Data) -> ParsedMessage {
        let bytes = [UInt8](raw)
        var state = State()
        var headerWarnings: [String] = []
        let block = HeaderParser.splitFields(bytes, in: 0..<bytes.count, warnings: &headerWarnings)
        let headers = headerParser.headers(from: block.fields, warnings: headerWarnings)
        walk(bytes, fields: block.fields, body: block.bodyStart..<bytes.count, path: [], depth: 0,
             defaultType: "text/plain", state: &state)

        var warnings = headers.warnings
        for warning in state.warnings where !warnings.contains(warning) { warnings.append(warning) }
        return ParsedMessage(
            headers: headers,
            textPlain: state.plain.isEmpty ? nil : state.plain.joined(separator: "\n\n"),
            textFromHTML: state.html.isEmpty ? nil : state.html.joined(separator: "\n\n"),
            attachments: state.attachments,
            warnings: warnings
        )
    }

    /// The body parts as a reader shows them (R9, D-409): the HTML source of
    /// every text/html body part, decoded with its charset, and the plain parts.
    /// Walks the same tree as `parse`, so the same parts count as body text;
    /// attachments are skipped without being decoded. Changes nothing `parse` stores.
    public func displayBody(_ raw: Data) -> (html: String?, plain: String?) {
        let bytes = [UInt8](raw)
        var state = State()
        state.keepHTMLSource = true
        var headerWarnings: [String] = []
        let block = HeaderParser.splitFields(bytes, in: 0..<bytes.count, warnings: &headerWarnings)
        walk(bytes, fields: block.fields, body: block.bodyStart..<bytes.count, path: [], depth: 0,
             defaultType: "text/plain", state: &state)
        return (state.html.isEmpty ? nil : state.html.joined(separator: "\n"),
                state.plain.isEmpty ? nil : state.plain.joined(separator: "\n\n"))
    }

    struct State {
        /// Keep each HTML part's source in `html` rather than its text, and skip attachments (`displayBody`).
        var keepHTMLSource = false
        var plain: [String] = []
        var html: [String] = []
        var attachments: [ParsedAttachment] = []
        var warnings: [String] = []
        var parts = 0

        mutating func warn(_ warning: String) {
            if !warnings.contains(warning) { warnings.append(warning) }
        }
    }

    // MARK: - Walking the tree

    private func walk(
        _ bytes: [UInt8], fields: [HeaderField], body: Range<Int>, path: [Int], depth: Int,
        defaultType: String, state: inout State
    ) {
        state.parts += 1
        guard state.parts <= Self.maximumParts else {
            state.warn("too many MIME parts, rest skipped")
            return
        }
        func field(_ name: String) -> String? {
            fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        let contentType = field("Content-Type").map(ContentField.parse)
        if contentType?.hadProblem == true { state.warn("malformed Content-Type parameters") }
        var type = contentType?.value ?? defaultType
        if !type.contains("/") {
            if contentType != nil { state.warn("malformed Content-Type") }
            type = defaultType
        }
        let disposition = field("Content-Disposition").map(ContentField.parse)
        if disposition?.hadProblem == true { state.warn("malformed Content-Disposition parameters") }

        if type.hasPrefix("multipart/") {
            guard depth < Self.maximumDepth else {
                state.warn("MIME nesting too deep, rest skipped")
                return
            }
            guard let boundary = contentType?[parameter: "boundary"], !boundary.isEmpty else {
                state.warn("multipart without boundary, read as text")
                leaf(bytes, fields: fields, body: body, path: path, type: "text/plain",
                     contentType: nil, disposition: disposition, state: &state)
                return
            }
            let parts = splitMultipart(bytes, body: body, boundary: boundary, state: &state)
            if parts.isEmpty {
                leaf(bytes, fields: fields, body: body, path: path, type: "text/plain",
                     contentType: nil, disposition: disposition, state: &state)
                return
            }
            let childDefault = type == "multipart/digest" ? "message/rfc822" : "text/plain"
            for (index, part) in parts.enumerated() {
                var warnings: [String] = []
                let block = HeaderParser.splitFields(bytes, in: part, warnings: &warnings)
                for warning in warnings { state.warn(warning) }
                walk(bytes, fields: block.fields, body: block.bodyStart..<part.upperBound, path: path + [index + 1],
                     depth: depth + 1, defaultType: childDefault, state: &state)
            }
            return
        }

        if type == "message/rfc822" || type == "message/global",
           TransferDecoding.Encoding(header: field("Content-Transfer-Encoding")) == .identity {
            guard depth < Self.maximumDepth else {
                state.warn("MIME nesting too deep, rest skipped")
                return
            }
            // A forwarded message: open it.
            var warnings: [String] = []
            let block = HeaderParser.splitFields(bytes, in: body, warnings: &warnings)
            let nested = headerParser.headers(from: block.fields)
            state.plain.append(forwardedHeading(nested))
            let nestedPath = path.isEmpty ? [1] : path
            walk(bytes, fields: block.fields, body: block.bodyStart..<body.upperBound, path: nestedPath,
                 depth: depth + 1, defaultType: "text/plain", state: &state)
            return
        }

        leaf(bytes, fields: fields, body: body, path: path, type: type,
             contentType: contentType, disposition: disposition, state: &state)
    }

    /// A single-part entity: body text or an attachment.
    private func leaf(
        _ bytes: [UInt8], fields: [HeaderField], body: Range<Int>, path: [Int], type: String,
        contentType: ContentField?, disposition: ContentField?, state: inout State
    ) {
        func field(_ name: String) -> String? {
            fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let filename = disposition?[parameter: "filename"] ?? contentType?[parameter: "name"]
        let dispositionValue = disposition?.value
        let isAttachment = dispositionValue == "attachment"
        // A text part is body text unless it is marked as an attachment, or
        // carries a file name without saying "inline".
        let isBodyText = (type == "text/plain" || type == "text/html") && !isAttachment
            && (dispositionValue == "inline" || filename == nil)
        if state.keepHTMLSource, !isBodyText { return }

        let encodingHeader = field("Content-Transfer-Encoding")
        let encoding = TransferDecoding.Encoding(header: encodingHeader)
        if encoding == .unknown { state.warn("unknown Content-Transfer-Encoding") }
        let (data, problem) = TransferDecoding.decode(bytes, body, encoding: encoding)
        if problem, encoding == .base64 { state.warn("invalid base64") }

        if isBodyText {
            let decoded = Charset.decode(data, charset: contentType?[parameter: "charset"])
            if decoded.usedFallback { state.warn("body text not in its declared charset") }
            // Search text reads at most a fixed amount per part (D-495); the
            // part is still stored whole, and shown whole when read.
            var text = decoded.text
            if !state.keepHTMLSource, text.utf8.count > TextExtractor.maximumTextBytes {
                text = TextExtractor.capped(text)
                state.warn("body text cut for search at \(TextExtractor.maximumTextBytes >> 20) MB")
            }
            if type == "text/html" {
                state.html.append(state.keepHTMLSource ? text : HTMLText.text(fromHTML: text))
            } else {
                state.plain.append(text.replacingOccurrences(of: "\r\n", with: "\n"))
            }
            return
        }

        let contentID = field("Content-ID").flatMap { AddressListParser.messageIDs($0).first }
        let partPath = path.isEmpty ? "1" : path.map(String.init).joined(separator: ".")
        state.attachments.append(ParsedAttachment(
            partPath: partPath,
            filename: filename?.isEmpty == false ? filename : nil,
            declaredMimeType: type,
            disposition: dispositionValue == "inline" ? .inline : .attachment,
            contentID: contentID,
            data: data,
            encodedRange: body,
            transferEncoding: encodingHeader?.trimmingCharacters(in: .whitespaces).lowercased()
        ))
    }

    /// A short heading for a forwarded message's text, so its sender and subject are searchable.
    private func forwardedHeading(_ headers: MessageHeaders) -> String {
        var lines = ["---------- Forwarded message ----------"]
        if let from = headers.from.first {
            lines.append("From: " + [from.name, from.address].compactMap { $0 }.joined(separator: " "))
        }
        if let subject = headers.subject { lines.append("Subject: " + subject) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Multipart

    /// Finds the parts between `--boundary` lines. Each range excludes the
    /// line break before the next delimiter (RFC 2046 section 5.1.1).
    private func splitMultipart(_ bytes: [UInt8], body: Range<Int>, boundary: String, state: inout State) -> [Range<Int>] {
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [Range<Int>] = []
        var partStart: Int?
        var closed = false
        var lineStart = body.lowerBound

        while lineStart < body.upperBound {
            let lineEnd = Self.nextLineFeed(bytes, from: lineStart, to: body.upperBound)
            let next = min(lineEnd + 1, body.upperBound)

            if lineEnd - lineStart >= delimiter.count, bytes[lineStart] == 0x2D,
               bytes[lineStart..<(lineStart + delimiter.count)].elementsEqual(delimiter) {
                var rest = lineStart + delimiter.count
                let isClose = rest + 1 < lineEnd && bytes[rest] == 0x2D && bytes[rest + 1] == 0x2D
                if isClose { rest += 2 }
                // Only whitespace may follow the delimiter on its line.
                let tail = bytes[rest..<lineEnd]
                if tail.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    if let start = partStart {
                        parts.append(start..<trimLineBreak(bytes, start: start, end: lineStart))
                    }
                    if isClose {
                        closed = true
                        break
                    }
                    partStart = next
                }
            }
            lineStart = next
        }
        if !closed {
            if let start = partStart {
                state.warn("multipart without closing boundary")
                parts.append(start..<body.upperBound)
            } else {
                state.warn("multipart boundary not found")
            }
        }
        return parts
    }

    /// Index of the next line feed in `bytes[start..<end]`, or `end`. Uses
    /// `memchr`, which is far faster than a Swift loop on multi-megabyte bodies.
    static func nextLineFeed(_ bytes: [UInt8], from start: Int, to end: Int) -> Int {
        guard start < end else { return end }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress,
                  let found = memchr(base + start, 0x0A, end - start)
            else { return end }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
    }

    /// The line break before a delimiter belongs to the delimiter, not the part.
    private func trimLineBreak(_ bytes: [UInt8], start: Int, end: Int) -> Int {
        var end = end
        if end > start, bytes[end - 1] == 0x0A { end -= 1 }
        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
        return end
    }
}
