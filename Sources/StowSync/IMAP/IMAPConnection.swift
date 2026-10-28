import Foundation
import Network
import NIOCore
import NIOIMAP
import NIOIMAPCore
import NIOTransportServices
import StowCore
import StowSecrets

/// One TCP (normally TLS) connection to an IMAP server, built on
/// swift-nio-imap and Network.framework.
///
/// Replies arrive as a stream of parsed `Response` values. Commands go out
/// only as `ReadOnlyCommand` (D-109). This type knows nothing about mail; the
/// `IMAPSession` actor on top of it does the IMAP conversation.
final class IMAPConnection: Sendable {
    let channel: Channel
    let responses: AsyncThrowingStream<Response, Error>
    /// Where this connection goes, so `send` can refuse a password without TLS.
    let endpoint: IMAPEndpoint

    private init(channel: Channel, responses: AsyncThrowingStream<Response, Error>, endpoint: IMAPEndpoint) {
        self.channel = channel
        self.responses = responses
        self.endpoint = endpoint
    }

    /// One event loop group for every connection in the process.
    static let group = NIOTSEventLoopGroup(loopCount: 1)

    /// The largest body literal the parser accepts (security review M-4).
    /// swift-nio-imap's default is unlimited. Exchange Online allows messages
    /// up to 150 MB and Gmail 50 MB, so a larger literal is a broken or hostile
    /// server; the parser then fails the connection instead of trusting it.
    static let bodySizeLimit: UInt64 = 256 << 20

    static func connect(to endpoint: IMAPEndpoint, timeouts: IMAPTimeouts) async throws -> IMAPConnection {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Response.self, throwing: Error.self)
        let readTimeout = TimeAmount.milliseconds(Int64(timeouts.read * 1000))
        var bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.milliseconds(Int64(timeouts.connect * 1000)))
            // Fail at once with Network.framework's own error instead of waiting
            // out the timeout, so a refused certificate is reported as one.
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        IdleStateHandler(readTimeout: readTimeout),
                        // Never let the parser see a read ending in a lone CR (D-120).
                        TrailingCRHandler(),
                        IMAPClientHandler(parserOptions: ResponseParser.Options(bodySizeLimit: Self.bodySizeLimit)),
                        ResponseForwarder(continuation: continuation),
                    ])
                }
            }
        if endpoint.useTLS {
            // System trust store and hostname check, TLS 1.2 or later.
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            bootstrap = bootstrap.tlsOptions(tls)
        }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            continuation.finish(throwing: error)
            if let network = error as? NWError, case .tls = network {
                throw SyncError.certificateRejected(Redact.scrub(String(describing: error)))
            }
            throw SyncError.connectionFailed(Redact.scrub(String(describing: error)))
        }
        continuation.onTermination = { _ in channel.close(promise: nil) }
        return IMAPConnection(channel: channel, responses: stream, endpoint: endpoint)
    }

    /// Refuses, before writing a byte, to send a password anywhere but an
    /// implicit-TLS connection to port 993 (D-467). Network.framework reports
    /// the channel active only once the TLS handshake and certificate check
    /// have passed, so on a TLS endpoint TLS is up by the time this runs.
    func send(tag: String, _ command: ReadOnlyCommand) async throws {
        guard !command.carriesPassword || endpoint.allowsPassword else {
            throw SyncError.insecureConnection
        }
        try await write(.tagged(TaggedCommand(tag: tag, command: command.command)))
    }

    /// Answers a SASL challenge with an empty line: XOAUTH2 uses a challenge
    /// to report failure, and the client must reply with an empty line.
    func sendEmptyContinuation() async throws {
        try await write(.continuationResponse(ByteBuffer()))
    }

    /// Answers the server's `+` to `AUTHENTICATE PLAIN` sent without an
    /// initial response (no SASL-IR). Same TLS rule as `send` (D-467).
    func sendPlainResponse(user: String, password: AppSpecificPassword) async throws {
        guard endpoint.allowsPassword else { throw SyncError.insecureConnection }
        try await write(.continuationResponse(ByteBuffer(bytes: SASLPlain.response(user: user, password: password))))
    }

    private func write(_ part: CommandStreamPart) async throws {
        do {
            try await channel.writeAndFlush(IMAPClientHandler.Message.part(part)).get()
        } catch {
            throw SyncError.connectionClosed(nil)
        }
    }

    func close() async {
        try? await channel.close().get()
    }
}

/// Passes each parsed response into an async stream, and turns read
/// timeouts, errors and closure into the end of that stream.
///
/// A read timeout only counts while a reply is expected: the greeting, or a
/// command that has been sent and not yet completed.
private final class ResponseForwarder: ChannelDuplexHandler {
    typealias InboundIn = Response
    typealias OutboundIn = IMAPClientHandler.Message
    typealias OutboundOut = IMAPClientHandler.Message

    private let continuation: AsyncThrowingStream<Response, Error>.Continuation
    private var awaitingGreeting = true
    private var outstandingCommands = 0

    init(continuation: AsyncThrowingStream<Response, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        awaitingGreeting = false
        if case .tagged = response { outstandingCommands = max(0, outstandingCommands - 1) }
        continuation.yield(response)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .part(.tagged) = unwrapOutboundIn(data) { outstandingCommands += 1 }
        context.write(data, promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read {
            if awaitingGreeting || outstandingCommands > 0 {
                continuation.finish(throwing: SyncError.timedOut)
                context.close(promise: nil)
            }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Network failures can be retried; a reply the parser cannot read cannot.
        // Only the error's type name is kept: parser errors can quote server bytes.
        let failure: SyncError
        if error is NWError || error is ChannelError || error is IOError {
            failure = .connectionClosed(Redact.scrub(String(describing: error)))
        } else {
            failure = .protocolViolation(String(describing: type(of: error)))
        }
        continuation.finish(throwing: failure)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }
}
