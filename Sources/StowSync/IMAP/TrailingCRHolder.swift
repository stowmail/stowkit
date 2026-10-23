import NIOCore

/// Works around a swift-nio-imap 0.4.0 parser bug that corrupts a message
/// when a network read ends exactly between the CR and LF of a literal
/// header such as `BODY[] {12735}\r` + `\n...` (D-120).
///
/// The parser accepts a lone CR at the end of its input as a line ending. In
/// "response" mode it later skips the orphaned LF, but after a literal header
/// it is in literal mode, where it does not: the LF becomes the literal's first
/// byte, the literal's real last byte is left over, and the parser then skips
/// it as the "orphaned LF". The message arrives as `"\n" + original[:-1]`,
/// the same length, so size checks cannot see it.
///
/// The cure is to never hand the parser input that ends in a lone CR: a
/// trailing CR is held back and put in front of the next bytes. IMAP lines end
/// in CRLF, so the LF always follows. Nothing is added, dropped or reordered.
struct TrailingCRHolder {
    /// Trailing CRs held back from earlier reads (almost always 0 or 1).
    private var heldCRs = 0

    /// The bytes to pass on now (possibly empty), given the bytes just read.
    /// What is passed on never ends in CR.
    mutating func process(_ input: ByteBuffer) -> ByteBuffer {
        var output: ByteBuffer
        if heldCRs > 0 {
            output = ByteBuffer()
            output.reserveCapacity(input.readableBytes + heldCRs)
            output.writeRepeatingByte(UInt8(ascii: "\r"), count: heldCRs)
            var copy = input
            output.writeBuffer(&copy)
            heldCRs = 0
        } else {
            output = input
        }
        while output.readableBytes > 0,
              output.getInteger(at: output.writerIndex - 1, as: UInt8.self) == UInt8(ascii: "\r") {
            output.moveWriterIndex(to: output.writerIndex - 1)
            heldCRs += 1
        }
        return output
    }

    /// Any held-back bytes, for when the connection closes.
    mutating func flush() -> ByteBuffer? {
        guard heldCRs > 0 else { return nil }
        var rest = ByteBuffer()
        rest.writeRepeatingByte(UInt8(ascii: "\r"), count: heldCRs)
        heldCRs = 0
        return rest
    }
}

/// Puts `TrailingCRHolder` in the channel pipeline, between TLS and the IMAP parser.
final class TrailingCRHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var holder = TrailingCRHolder()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let output = holder.process(unwrapInboundIn(data))
        if output.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(output))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let rest = holder.flush() {
            context.fireChannelRead(wrapInboundOut(rest))
        }
        context.fireChannelInactive()
    }
}
