import Foundation
import Network

/// Why waiting for the browser's OAuth redirect failed.
public enum LoopbackError: Error, Equatable, CustomStringConvertible {
    case timedOut
    case stateMismatch
    case missingCode
    /// The provider redirected with `error=...` (for example the user pressed Cancel).
    case providerError(String)
    case listenerFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .timedOut: "Sign-in timed out: no reply from the browser within five minutes."
        case .stateMismatch: "Sign-in rejected: the reply did not carry the expected state value, so it may not come from this sign-in."
        case .missingCode: "Sign-in failed: the reply had no authorisation code."
        case .providerError(let error): "The provider refused sign-in (\(error))."
        case .listenerFailed(let reason): "Could not listen for the sign-in reply: \(reason)"
        case .cancelled: "Sign-in cancelled."
        }
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect (D-102).
///
/// - Binds to 127.0.0.1 only, on a random free port, and accepts only local connections.
/// - The first `GET /` request is *the* callback: its `state` is checked against
///   the expected value and the listener closes straight after, whatever the
///   outcome. Other paths (such as `/favicon.ico`) get a 404 and are ignored.
/// - Gives up after the timeout (five minutes by default).
///
/// All mutable state is only touched on `queue`, which is why the class can be
/// marked `@unchecked Sendable`.
public final class LoopbackListener: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 5 * 60
    /// The only address the listener binds to.
    public static let bindHost = "127.0.0.1"
    static let maximumRequestBytes = 16 * 1024

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ee.getstow.oauth-loopback")
    private let expectedState: String
    private var outcome: Result<String, LoopbackError>?
    private var waiter: CheckedContinuation<String, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var closed = false
    /// How many requests reached the callback path. Exposed for tests.
    private var callbackCount = 0

    /// The port chosen by the system. Set once `start` returns.
    public private(set) var port: UInt16 = 0

    private init(listener: NWListener, expectedState: String) {
        self.listener = listener
        self.expectedState = expectedState
    }

    /// Opens the listener and waits until it is ready.
    public static func start(expectedState: String, timeout: TimeInterval = defaultTimeout) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters)
        } catch {
            throw LoopbackError.listenerFailed(String(describing: error))
        }
        let listener = LoopbackListener(listener: nwListener, expectedState: expectedState)
        try await listener.begin(timeout: timeout)
        return listener
    }

    private func begin(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    ready.resume(throwing: LoopbackError.cancelled)
                    return
                }
                self.readyContinuation = ready
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.listenerStateChanged(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(.timedOut))
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener.port?.rawValue ?? 0
            readyContinuation?.resume()
            readyContinuation = nil
        case .failed(let error):
            readyContinuation?.resume(throwing: LoopbackError.listenerFailed(String(describing: error)))
            readyContinuation = nil
            finish(.failure(.listenerFailed(String(describing: error))))
        default:
            break
        }
    }

    /// Waits for the callback and returns the authorisation code.
    public func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async {
                    if let outcome = self.outcome {
                        continuation.resume(with: outcome.mapError { $0 as Error })
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(.cancelled)) }
        }
    }

    /// Closes the listener. Safe to call more than once.
    public func close() {
        queue.async { self.finish(.failure(.cancelled)) }
    }

    /// True once the listener has stopped accepting connections. For tests.
    public var isClosed: Bool {
        queue.sync { closed }
    }

    var callbacksReceived: Int {
        queue.sync { callbackCount }
    }

    // MARK: On `queue`

    private func finish(_ result: Result<String, LoopbackError>) {
        guard outcome == nil else { return }
        outcome = result
        closed = true
        listener.newConnectionHandler = nil
        listener.cancel()
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result.mapError { $0 as Error })
        }
    }

    private func handle(_ connection: NWConnection) {
        guard outcome == nil else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequestLine.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if error != nil || isComplete || buffer.count >= Self.maximumRequestBytes {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequestLine, on connection: NWConnection) {
        guard outcome == nil else {
            send(status: "503 Service Unavailable", body: Self.page("This sign-in has already finished."), on: connection)
            return
        }
        guard request.method == "GET" else {
            send(status: "405 Method Not Allowed", body: Self.page("Not allowed."), on: connection)
            return
        }
        guard request.path == "/" else {
            send(status: "404 Not Found", body: Self.page("Not found."), on: connection)
            return
        }
        callbackCount += 1
        let result = Self.evaluate(request.query, expectedState: expectedState)
        switch result {
        case .success:
            send(status: "200 OK", body: Self.page("Signed in to Stow. You can close this window and return to the terminal."), on: connection)
        case .failure(let error):
            send(status: "400 Bad Request", body: Self.page("Sign-in did not complete: \(error.description) Return to the terminal for details."), on: connection)
        }
        finish(result)
    }

    /// Checks the callback's query: provider error first, then state, then code.
    static func evaluate(_ query: [String: String], expectedState: String) -> Result<String, LoopbackError> {
        if let error = query["error"] {
            // The error code is a short fixed word such as access_denied; the
            // free-text description is not kept, as it may carry personal detail.
            let safe = error.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(64)
            return .failure(.providerError(String(safe)))
        }
        guard let state = query["state"], constantTimeEqual(state, expectedState) else {
            return .failure(.stateMismatch)
        }
        guard let code = query["code"], !code.isEmpty else {
            return .failure(.missingCode)
        }
        return .success(code)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func page(_ message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>Stow</title></head>"
            + "<body style=\"font-family: -apple-system, sans-serif; margin: 3em\"><p>\(escaped)</p></body></html>"
    }
}

/// The first line of an HTTP request, split into method, path and query.
struct HTTPRequestLine: Equatable {
    var method: String
    var path: String
    var query: [String: String]

    /// Parses once the full header block (ending in a blank line) has arrived.
    static func parse(_ data: Data) -> HTTPRequestLine? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        guard let firstLine = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3 else { return HTTPRequestLine(method: "", path: "", query: [:]) }
        let target = String(parts[1])
        guard let components = URLComponents(string: target) else {
            return HTTPRequestLine(method: String(parts[0]), path: "", query: [:])
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        return HTTPRequestLine(method: String(parts[0]), path: components.path, query: query)
    }
}
