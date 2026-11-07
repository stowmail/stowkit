import Foundation
import Logging
import StowCore

/// Reads one Gmail account through the Gmail API (D-583).
///
/// `send` takes only a `GmailReadOnlyRequest`, so every call is one of the five
/// GETs that list could express. The access token comes from `TokenProvider`
/// for each call, refreshed ahead of expiry, and once more after a 401; it is
/// passed to the transport alone and never appears in a URL, log line, error
/// or description.
struct GmailClient: Sendable {
    /// Hands out an access token; `true` asks for a fresh one.
    typealias AccessToken = @Sendable (_ forceRefresh: Bool) async throws -> String

    let account: AccountID
    let transport: any GmailTransport
    private let accessToken: AccessToken
    private let markNeedsSignIn: @Sendable () async throws -> Void
    /// Keeps the account under Google's per-user quota (D-598); nil in tests
    /// that do not measure pacing.
    private let pacer: GmailQuotaPacer?
    private let logger = Logger(label: "ee.getstow.sync.gmail")

    init(account: AccountID, transport: any GmailTransport = URLSessionGmailTransport(),
         markNeedsSignIn: @escaping @Sendable () async throws -> Void, pacer: GmailQuotaPacer? = nil,
         accessToken: @escaping AccessToken) {
        self.account = account
        self.transport = transport
        self.pacer = pacer
        self.markNeedsSignIn = markNeedsSignIn
        self.accessToken = accessToken
    }

    init(account: AccountID, tokens: TokenProvider, transport: any GmailTransport = URLSessionGmailTransport()) {
        self.init(account: account, transport: transport, markNeedsSignIn: { try await tokens.permissionMissing(account) },
                  pacer: GmailQuotaPacer()) { force in
            try await tokens.accessToken(for: account, forceRefresh: force)
        }
    }

    /// Sends one request and returns the body of a 2xx reply. A 401 is tried
    /// once more with a refreshed token, and only once. Throws `GmailNotFound`
    /// on a 404, which callers read (a message gone, a history ID too old);
    /// every other failure is a `SyncError` (D-082), each with its own message
    /// (D-592). Only a missing read permission marks the account.
    func send(_ request: GmailReadOnlyRequest) async throws -> Data {
        let get = request.get
        try await pacer?.spend(request.quotaUnits)
        var response = try await transport.send(get, accessToken: try await accessToken(false))
        if response.status == 401 {
            logger.info("Gmail refused the access token; refreshing once", metadata: ["call": "\(get.name)"])
            try await pacer?.spend(request.quotaUnits)
            response = try await transport.send(get, accessToken: try await accessToken(true))
        }
        if (200..<300).contains(response.status) { return response.body }
        let reason = GmailErrorBody.reason(in: response.body)
        let failure = Self.failure(status: response.status, reason: reason, retryAfter: response.retryAfter, call: get.name, account: account)
        let metadata: Logger.Metadata = ["call": "\(get.name)", "status": "\(response.status)", "reason": "\(reason ?? "none")"]
        if case SyncError.gmailAPIUnavailable = failure {
            logger.error("Gmail API refused Stow's project", metadata: metadata)
        } else {
            logger.notice("Gmail call failed", metadata: metadata)
        }
        if case SyncError.permissionMissing = failure { try await markNeedsSignIn() }
        throw failure
    }

    /// Sends a request and decodes its reply.
    func fetch<Reply: Decodable>(_ request: GmailReadOnlyRequest, as _: Reply.Type = Reply.self) async throws -> Reply {
        let body = try await send(request)
        do {
            return try JSONDecoder().decode(Reply.self, from: body)
        } catch {
            throw SyncError.protocolViolation("Gmail sent a \(request.name) reply Stow could not read")
        }
    }

    func profile() async throws -> GmailProfile { try await fetch(.profile) }

    func labels() async throws -> [GmailLabel] { try await fetch(.labels, as: GmailLabelList.self).labels }

    func messages(_ query: GmailMessageListQuery) async throws -> GmailMessageList { try await fetch(.messages(query)) }

    func message(_ id: GmailMessageID, format: GmailMessageFormat) async throws -> GmailMessage {
        let message: GmailMessage = try await fetch(.message(id, format: format))
        guard message.id == id else { throw SyncError.protocolViolation("Gmail answered users.messages.get with another message") }
        if format == .raw, message.raw == nil { throw SyncError.protocolViolation("Gmail sent no raw message") }
        return message
    }

    func history(_ query: GmailHistoryQuery) async throws -> GmailHistoryList { try await fetch(.history(query)) }

    /// A failed reply as the error Stow shows. Only the status and Google's
    /// short reason code are kept, never its free-text message.
    static func failure(status: Int, reason: String?, retryAfter: TimeInterval?, call: String, account: AccountID) -> Error {
        let detail = "HTTP \(status)\(reason.map { ", \($0)" } ?? "")"
        let wait = retryAfter.map { ", retry after \(Int($0)) s" } ?? ""
        switch (status, reason) {
        case (404, _):
            return GmailNotFound(call: call)
        case (429, _), (403, "rateLimitExceeded"), (403, "userRateLimitExceeded"):
            return SyncError.throttled("Gmail (\(detail)\(wait))")
        case (403, "dailyLimitExceeded"), (403, "quotaExceeded"):
            return SyncError.quotaExceeded("Gmail (\(detail))")
        case (403, "insufficientPermissions"), (403, "ACCESS_TOKEN_SCOPE_INSUFFICIENT"):
            return SyncError.permissionMissing(account)
        case (403, "domainPolicy"):
            return SyncError.blockedByAdmin
        case (403, "accessNotConfigured"), (403, "SERVICE_DISABLED"):
            return SyncError.gmailAPIUnavailable
        case (401, _):
            return SyncError.authenticationFailed("Gmail refused the access token twice, \(detail)")
        case (500..<600, _):
            return SyncError.providerUnavailable("Gmail (\(detail)\(wait))")
        default:
            return SyncError.commandFailed(command: call, status: "HTTP \(status)", text: reason ?? "no reason given")
        }
    }
}

/// Gmail answered 404: the message no longer exists, or a history ID is too
/// old to list changes from. Callers decide what that means.
struct GmailNotFound: Error, Equatable, CustomStringConvertible {
    let call: String
    var description: String { "Gmail found nothing for \(call) (HTTP 404)." }
}
