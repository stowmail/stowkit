import Foundation

// libFuzzer target for the streaming mbox reader (B2-06, D-559). Built by
// scripts/fuzz.sh mbox, never by Package.swift.
//
// Besides not crashing, the reader must give the same messages and counts
// however the file is cut into reads, and its offsets must stay in order and
// inside the file. The first input byte picks the read size and buffer, so
// libFuzzer explores the boundaries too.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafeRawPointer?, _ count: Int) -> CInt {
    let raw = start.map { [UInt8](UnsafeRawBufferPointer(start: $0, count: count)) } ?? []
    guard let shape = raw.first else { return 0 }
    let file = raw.dropFirst()
    let step = Int(shape & 0x3F) + 1
    let variant: MboxVariant = shape & 0x40 == 0 ? .mboxrd : .mboxo
    let whole = read(MboxReader(MboxBytes(file), variant: variant, maximumMessageBytes: 4096))
    let cut = read(MboxReader(MboxBytes(file, step: step), variant: variant, chunkBytes: step * 3,
                              maximumLineBytes: 1100, maximumMessageBytes: 4096))
    guard whole.error == cut.error, whole.messages == cut.messages else { fatalError("reads differ with step \(step)") }
    guard whole.error != nil || whole.counts == cut.counts else { fatalError("counts differ with step \(step)") }
    var previous: Int64 = -1
    for message in whole.messages {
        guard message.offset > previous, message.endOffset > message.offset, message.endOffset <= Int64(file.count),
              message.size <= Int(message.endOffset - message.offset), message.problem == .tooLarge || message.bytes.count == message.size
        else { fatalError("offsets or sizes out of order") }
        previous = message.offset
    }
    return 0
}

private func read<Source>(_ reader: MboxReader<Source>) -> (messages: [MboxMessage], counts: MboxReadCounts, error: MboxReadError?) {
    var reader = reader
    var messages: [MboxMessage] = []
    do {
        while let message = try reader.next() { messages.append(message) }
    } catch let error as MboxReadError {
        return (messages, reader.counts, error)
    } catch {
        fatalError("unexpected error")
    }
    return (messages, reader.counts, nil)
}
