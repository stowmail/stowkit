import Foundation

// The streaming mbox reader (B2-06, D-558, D-559). Foundation only, so the fuzz
// target (Fuzz/MboxFuzz.swift) builds it on its own.

/// How `>From ` lines are read back (D-558). The two differ only on lines that
/// start with two or more `>` before `From `.
public enum MboxVariant: String, Sendable, Codable, CaseIterable {
    /// One `>` comes off every line that starts with one or more `>` and then
    /// `From ` (what Stow's own export writes, D-042). The default.
    case mboxrd
    /// One `>` comes off a line that starts with exactly `>From `.
    case mboxo
}

/// Something wrong with one message in the file. The message is still
/// reported, so it can be counted; what to do with it is the importer's call.
public enum MboxProblem: String, Sendable, Equatable {
    /// The file ended part way through the message's last line, so the file
    /// was probably cut short (a copy that did not finish, a full disk).
    case cutShort
    /// Larger than the reader's `maximumMessageBytes`. Its bytes were read
    /// past, not kept, so memory stays flat (D-559).
    case tooLarge
}

/// One message from an mbox file, with the framing undone: no `From ` line,
/// no blank line the writer added after it, and `>From ` quoting taken off.
/// Every other byte is as stored in the file: line endings, charsets and NUL
/// bytes included.
public struct MboxMessage: Sendable, Equatable {
    /// Byte offset of the message's `From ` line in the file.
    public var offset: Int64
    /// Byte offset just past the message: where the next `From ` line starts,
    /// or the end of the file. An import that committed this message resumes here.
    public var endOffset: Int64
    /// The `From ` line, without its line break.
    public var separator: Data
    /// The message. Empty when `problem` is `tooLarge`.
    public var bytes: Data
    /// The message's size with the framing undone, also when it was too large to keep.
    public var size: Int
    public var problem: MboxProblem?
    /// Holds at least one NUL byte (kept: the bytes are not changed).
    public var containsNUL: Bool
    /// Has at least one line ending in CR LF.
    public var usesCRLF: Bool

    public init(offset: Int64, endOffset: Int64, separator: Data, bytes: Data, size: Int,
                problem: MboxProblem? = nil, containsNUL: Bool = false, usesCRLF: Bool = false) {
        self.offset = offset
        self.endOffset = endOffset
        self.separator = separator
        self.bytes = bytes
        self.size = size
        self.problem = problem
        self.containsNUL = containsNUL
        self.usesCRLF = usesCRLF
    }
}

/// What the reader saw so far. Counts only, never content.
public struct MboxReadCounts: Sendable, Equatable {
    public var messages = 0
    /// Bytes of the file read so far, framing included.
    public var bytesRead: Int64 = 0
    /// Blank lines before the first `From ` line, skipped.
    public var bytesBeforeFirstMessage = 0
    /// Lines starting with `From ` that did not start a message, because no
    /// blank line came before them or they are not shaped like a `From ` line.
    /// Kept in their message exactly as they are.
    public var fromLinesKept = 0
    /// Of those, the ones shaped like a `From ` line but with no blank line
    /// before. A file with many of these may come from a writer that leaves
    /// out the blank line; they are counted so that shows (D-558).
    public var separatorsWithoutBlankLine = 0
    /// Lines that had one `>` taken off.
    public var linesUnquoted = 0
    public var cutShort = 0
    public var tooLarge = 0
    public var empty = 0
    public var withNUL = 0
    public var withCRLF = 0

    public init() {}
}

public enum MboxReadError: Error, Equatable, CustomStringConvertible {
    /// The first line that is not blank is not a `From ` line.
    case notAnMbox
    /// Resuming: the line at this offset is not a `From ` line, so the file changed.
    case notAtMessageStart(Int64)
    case readFailed(Int32)

    public var description: String {
        switch self {
        case .notAnMbox: "This is not an mbox file: it does not start with a \"From \" line."
        case .notAtMessageStart(let offset): "No message starts at byte \(offset) of the file; it has changed since the import began."
        case .readFailed(let code): "Could not read the file (\(String(cString: strerror(code))))."
        }
    }
}

/// Where the reader gets its bytes: a file, or memory in tests and the fuzz target.
public protocol MboxByteSource {
    /// Fills the start of `buffer` and returns how many bytes it wrote; 0 at the end.
    mutating func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}

/// An mbox file opened for reading, from `offset` on.
public final class MboxFile: MboxByteSource {
    private let descriptor: Int32

    public init(url: URL, offset: Int64 = 0) throws {
        descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MboxReadError.readFailed(errno) }
        if offset > 0, lseek(descriptor, off_t(offset), SEEK_SET) < 0 {
            let code = errno
            close(descriptor)
            throw MboxReadError.readFailed(code)
        }
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while true {
            let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            if count >= 0 { return count }
            if errno != EINTR { throw MboxReadError.readFailed(errno) }
        }
    }

    deinit { close(descriptor) }
}

/// Bytes in memory as a source.
public struct MboxBytes: MboxByteSource {
    private let bytes: [UInt8]
    private var position = 0
    /// At most this many bytes per read, so tests can cut reads anywhere.
    private let step: Int

    public init(_ bytes: some Sequence<UInt8>, step: Int = .max) {
        self.bytes = Array(bytes)
        self.step = max(1, step)
    }

    public mutating func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = min(buffer.count, bytes.count - position, step)
        guard count > 0 else { return 0 }
        bytes.withUnsafeBytes { source in
            buffer.baseAddress!.copyMemory(from: source.baseAddress! + position, byteCount: count)
        }
        position += count
        return count
    }
}

/// Reads an mbox file one message at a time with a fixed-size buffer, so a
/// 50 GB Google Takeout file never loads whole (D-559).
///
/// A message starts at a line beginning `From ` that comes first in the file
/// or right after a blank line, and is shaped like a `From ` line: a sender,
/// then a time (`09:27` or `09:27:00`) and a four-digit year somewhere after
/// it. Anything else starting with `From ` is part of the message it is in,
/// and counted. The blank line before a `From ` line, and one at the end of
/// the file, belong to the framing and are taken off. Lines longer than
/// `maximumLineBytes` are passed through in pieces; only their first piece
/// is looked at for quoting.
public struct MboxReader<Source: MboxByteSource> {
    public let variant: MboxVariant
    /// Messages larger than this are reported as `tooLarge` without their bytes.
    public let maximumMessageBytes: Int
    public private(set) var counts = MboxReadCounts()

    private var source: Source
    private let chunkBytes: Int
    private let maximumLineBytes: Int
    private var buffer: [UInt8]
    private var start = 0
    private var end = 0
    /// Where in `buffer[start..<end]` to carry on looking for a line feed.
    private var searched = 0
    /// File offset of `buffer[0]`.
    private var bufferOffset: Int64
    private let startOffset: Int64
    private var atEnd = false
    /// The last piece handed out did not end its line.
    private var insideLine = false
    private var begun = false
    /// The `From ` line of the next message, found while reading the one before.
    private var nextSeparator: (offset: Int64, line: Data)?

    /// `offset` is where `source` starts in the file. Resuming at an offset
    /// above 0 needs a `From ` line exactly there.
    public init(
        _ source: Source, variant: MboxVariant = .mboxrd, offset: Int64 = 0,
        chunkBytes: Int = 1_048_576, maximumLineBytes: Int = 65_536,
        maximumMessageBytes: Int = MboxLimits.defaultMaximumMessageBytes
    ) {
        self.source = source
        self.variant = variant
        self.chunkBytes = max(1, chunkBytes)
        self.maximumLineBytes = max(MboxLimits.maximumSeparatorBytes + 2, maximumLineBytes)
        self.maximumMessageBytes = max(0, maximumMessageBytes)
        buffer = [UInt8](repeating: 0, count: self.maximumLineBytes + self.chunkBytes)
        bufferOffset = offset
        startOffset = offset
    }

    /// The next message, or nil at the end of the file.
    public mutating func next() throws -> MboxMessage? {
        if !begun {
            begun = true
            try findFirstMessage()
        }
        guard let separator = nextSeparator else { return nil }
        nextSeparator = nil

        var bytes = [UInt8]()
        var size = 0
        var tooLarge = false
        var containsNUL = false
        var usesCRLF = false
        var lastBlankLength = 0
        var lastEndedLine = true
        var endOffset = bufferOffset + Int64(start)

        while let line = try nextLine() {
            let range = line.range
            if line.isStart, lastBlankLength > 0, line.isComplete, isSeparator(range, endsLine: line.endsLine) {
                nextSeparator = (line.offset, Data(buffer[range.lowerBound..<lineBody(range, endsLine: line.endsLine)]))
                endOffset = line.offset
                // The blank line before it is framing.
                size -= lastBlankLength
                if !tooLarge { bytes.removeLast(lastBlankLength) }
                lastBlankLength = 0
                break
            }
            var first = range.lowerBound
            if line.isStart, startsWithFrom(range.lowerBound, range.upperBound) {
                counts.fromLinesKept += 1
                if line.isComplete, isSeparator(range, endsLine: line.endsLine) { counts.separatorsWithoutBlankLine += 1 }
            } else if line.isStart, isQuoted(range) {
                first += 1
                counts.linesUnquoted += 1
            }
            let length = range.upperBound - first
            if !tooLarge, size + length > maximumMessageBytes {
                tooLarge = true
                bytes = []
            }
            if !tooLarge { bytes.append(contentsOf: buffer[first..<range.upperBound]) }
            size += length
            if !containsNUL, contains(0, first, range.upperBound) { containsNUL = true }
            if line.endsLine, range.count >= 2, buffer[range.upperBound - 2] == 0x0D { usesCRLF = true }
            lastBlankLength = line.isStart && line.endsLine && isBlank(range) ? range.count : 0
            lastEndedLine = line.endsLine
            endOffset = line.offset + Int64(range.count)
        }
        if nextSeparator == nil, lastBlankLength > 0 {
            // A blank line at the end of the file is the writer's, as before a `From ` line.
            size -= lastBlankLength
            if !tooLarge { bytes.removeLast(lastBlankLength) }
        }

        var problem: MboxProblem?
        if tooLarge {
            problem = .tooLarge
            counts.tooLarge += 1
        } else if !lastEndedLine, size > 0 {
            problem = .cutShort
            counts.cutShort += 1
        }
        counts.messages += 1
        if size == 0 { counts.empty += 1 }
        if containsNUL { counts.withNUL += 1 }
        if usesCRLF { counts.withCRLF += 1 }
        return MboxMessage(offset: separator.offset, endOffset: endOffset, separator: separator.line,
                           bytes: Data(bytes), size: size, problem: problem, containsNUL: containsNUL, usesCRLF: usesCRLF)
    }

    // MARK: - Lines

    private struct Line {
        /// The line's bytes in `buffer`, line feed included when it has one.
        var range: Range<Int>
        var offset: Int64
        /// The first piece of its line (a long line comes in pieces).
        var isStart: Bool
        /// Ends in a line feed.
        var endsLine: Bool
        /// The whole line: the start, and it ends in a line feed or at the end of the file.
        var isComplete: Bool
    }

    /// Skips blank lines at the start; the first other line must be a `From ` line.
    private mutating func findFirstMessage() throws {
        let resuming = startOffset > 0
        while let line = try nextLine() {
            let range = line.range
            if !resuming, line.isStart, line.endsLine, isBlank(range) {
                counts.bytesBeforeFirstMessage += range.count
                continue
            }
            guard line.isComplete, isSeparator(range, endsLine: line.endsLine) else {
                throw resuming ? MboxReadError.notAtMessageStart(startOffset) : MboxReadError.notAnMbox
            }
            nextSeparator = (line.offset, Data(buffer[range.lowerBound..<lineBody(range, endsLine: line.endsLine)]))
            return
        }
    }

    /// The next line, or piece of a long line. Its range is valid until the next call.
    private mutating func nextLine() throws -> Line? {
        while true {
            if start < end {
                let from = start + searched
                if let found = index(of: 0x0A, from, end) {
                    return take(upTo: found + 1, endsLine: true)
                }
                searched = end - start
                if end - start >= maximumLineBytes { return take(upTo: end, endsLine: false) }
            }
            if atEnd {
                guard start < end else { return nil }
                return take(upTo: end, endsLine: false)
            }
            try fill()
        }
    }

    private mutating func take(upTo stop: Int, endsLine: Bool) -> Line {
        let isStart = !insideLine
        insideLine = !endsLine && !(atEnd && stop == end)
        let line = Line(range: start..<stop, offset: bufferOffset + Int64(start), isStart: isStart,
                        endsLine: endsLine, isComplete: isStart && !insideLine)
        counts.bytesRead += Int64(stop - start)
        start = stop
        searched = 0
        return line
    }

    /// Moves what is left to the front of the buffer and reads more after it.
    private mutating func fill() throws {
        if start > 0 {
            let left = end - start
            if left > 0 {
                buffer.withUnsafeMutableBytes { raw in
                    raw.baseAddress!.copyMemory(from: raw.baseAddress! + start, byteCount: left)
                }
            }
            bufferOffset += Int64(start)
            end = left
            start = 0
        }
        let room = min(chunkBytes, buffer.count - end)
        let count = try buffer.withUnsafeMutableBytes { raw in
            try source.read(into: UnsafeMutableRawBufferPointer(rebasing: raw[end..<(end + room)]))
        }
        if count == 0 { atEnd = true } else { end += count }
    }

    // MARK: - Looking at a line

    private func index(of byte: UInt8, _ from: Int, _ to: Int) -> Int? {
        guard from < to else { return nil }
        return buffer.withUnsafeBytes { raw in
            memchr(raw.baseAddress! + from, Int32(byte), to - from).map { raw.baseAddress!.distance(to: UnsafeRawPointer($0)) }
        }
    }

    private func contains(_ byte: UInt8, _ from: Int, _ to: Int) -> Bool {
        index(of: byte, from, to) != nil
    }

    /// End of the line's text: before CR LF or LF.
    private func lineBody(_ range: Range<Int>, endsLine: Bool) -> Int {
        guard endsLine else { return range.upperBound }
        var stop = range.upperBound - 1
        if stop > range.lowerBound, buffer[stop - 1] == 0x0D { stop -= 1 }
        return stop
    }

    /// `\n` or `\r\n` alone.
    private func isBlank(_ range: Range<Int>) -> Bool {
        range.count == 1 || (range.count == 2 && buffer[range.lowerBound] == 0x0D)
    }

    private func startsWithFrom(_ from: Int, _ to: Int) -> Bool {
        to - from >= 5 && buffer[from] == 0x46 && buffer[from + 1] == 0x72 && buffer[from + 2] == 0x6F
            && buffer[from + 3] == 0x6D && buffer[from + 4] == 0x20
    }

    /// Quoted under this variant: `>From ` (mboxo), or any number of `>` then `From ` (mboxrd).
    private func isQuoted(_ range: Range<Int>) -> Bool {
        guard range.count >= 6, buffer[range.lowerBound] == 0x3E else { return false }
        var probe = range.lowerBound + 1
        if variant == .mboxrd {
            while probe < range.upperBound, buffer[probe] == 0x3E { probe += 1 }
        }
        return startsWithFrom(probe, range.upperBound)
    }

    private func isSeparator(_ range: Range<Int>, endsLine: Bool) -> Bool {
        let stop = lineBody(range, endsLine: endsLine)
        guard stop - range.lowerBound <= MboxLimits.maximumSeparatorBytes, startsWithFrom(range.lowerBound, stop) else { return false }
        return MboxSeparator.isShaped(buffer[(range.lowerBound + 5)..<stop])
    }
}

/// The reader's limits (D-559).
public enum MboxLimits {
    /// Gmail takes messages up to 50 MB; this leaves room for base64 and
    /// other mailers while keeping memory bounded.
    public static let defaultMaximumMessageBytes = 160 * 1_048_576
    /// A `From ` line longer than this is not one.
    static let maximumSeparatorBytes = 1000
}

/// The `From ` line that starts each message.
public enum MboxSeparator {
    /// After `From `: a sender, then somewhere a time and a four-digit year.
    static func isShaped(_ rest: ArraySlice<UInt8>) -> Bool {
        let words = rest.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 })
        guard words.count >= 3, rest.first != 0x20, rest.first != 0x09 else { return false }
        let after = words.dropFirst()
        return after.contains(where: isTime) && after.contains(where: isYear)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// `9:27`, `09:27` or `09:27:00`.
    static func isTime(_ word: ArraySlice<UInt8>) -> Bool {
        let parts = word.split(separator: 0x3A, omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, (1...2).contains(parts[0].count) else { return false }
        return parts.allSatisfy { $0.allSatisfy(isDigit) } && parts.dropFirst().allSatisfy { $0.count == 2 }
    }

    static func isYear(_ word: ArraySlice<UInt8>) -> Bool {
        word.count == 4 && word.allSatisfy(isDigit)
    }

    /// The date on a `From ` line (`From x Thu Oct 23 09:27:00 2026`, with an
    /// optional `+0000` before the year as Google Takeout writes it). UTC when
    /// no zone is given. Nil when it does not read.
    public static func date(_ line: Data) -> Date? {
        let words = line.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 }).map { String(decoding: $0, as: UTF8.self) }
        guard words.count >= 6, words[0] == "From" else { return nil }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        var components = DateComponents()
        var zone = 0
        for (index, word) in words.enumerated().dropFirst(2) {
            if let month = months.firstIndex(of: word.lowercased()), components.month == nil {
                components.month = month + 1
                if index + 1 < words.count, let day = Int(words[index + 1]), (1...31).contains(day) { components.day = day }
            } else if isTime(ArraySlice(word.utf8)) {
                let parts = word.split(separator: ":").compactMap { Int($0) }
                components.hour = parts[0]
                components.minute = parts[1]
                components.second = parts.count > 2 ? parts[2] : 0
            } else if isYear(ArraySlice(word.utf8)), components.hour != nil {
                components.year = Int(word)
            } else if word.count == 5, let sign = word.first, sign == "+" || sign == "-", let value = Int(word.dropFirst()) {
                zone = (sign == "-" ? -1 : 1) * ((value / 100) * 3600 + (value % 100) * 60)
            }
        }
        guard components.month != nil, components.day != nil, components.year != nil, components.hour != nil,
              (0...23).contains(components.hour!), (0...59).contains(components.minute!), (0...60).contains(components.second!)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: zone) ?? TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }
}
