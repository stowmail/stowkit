import Foundation

/// What came back from one Gmail API call.
struct GmailHTTPResponse: Sendable {
    var status: Int
    var body: Data
    /// `Retry-After`, in seconds, when Google sent one as a number.
    var retryAfter: TimeInterval?
}

/// Sends a `GmailGet` with a bearer token. Abstracted so tests can play
/// Google without a network. A transport is only ever handed a `GmailGet`,
/// which only `GmailReadOnlyRequest` can build.
protocol GmailTransport: Sendable {
    func send(_ request: GmailGet, accessToken: String) async throws -> GmailHTTPResponse
}

/// The real network: an ephemeral URLSession (no cookies, cache or credential
/// store, nothing written to disk), TLS with the system's trust and no
/// certificate exceptions, and no redirects followed, so the token is only ever
/// sent to `gmail.googleapis.com`.
final class URLSessionGmailTransport: GmailTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    func send(_ request: GmailGet, accessToken: String) async throws -> GmailHTTPResponse {
        guard request.url.scheme == "https", request.url.host == GmailReadOnlyRequest.host else {
            throw SyncError.protocolViolation("A Gmail request was not for \(GmailReadOnlyRequest.host)")
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = GmailGet.method
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.syncError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.protocolViolation("Gmail sent a reply that was not HTTP")
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        return GmailHTTPResponse(status: http.statusCode, body: data, retryAfter: retryAfter)
    }

    /// URLSession's errors as Stow's. The system's text is not kept: it can
    /// hold the request URL.
    static func syncError(_ error: Error) -> SyncError {
        guard let urlError = error as? URLError else { return .connectionFailed("the request to Gmail failed") }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired, .secureConnectionFailed:
            return .certificateRejected("URL error \(urlError.code.rawValue)")
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .connectionFailed("this Mac is offline")
        case .cannotFindHost, .dnsLookupFailed:
            return .connectionFailed("\(GmailReadOnlyRequest.host) could not be found (DNS)")
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            return .protocolViolation("Gmail tried to redirect the request")
        default:
            return .connectionFailed("URL error \(urlError.code.rawValue)")
        }
    }
}

/// Answers every redirect by not following it. The 3xx itself comes back and
/// is treated as an unexpected reply.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
