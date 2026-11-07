import CryptoKit
import Foundation
import Logging
import StowCore

/// `stowmail verify --server` for Gmail (D-593): re-fetches archived messages
/// through the Gmail API in `raw` format and checks they are byte for byte what
/// Gmail holds, as `StoreVerifier` does over IMAP (D-121). Same sampling, same
/// report. Writes nothing to the archive; downloads count against the
/// account's byte budget.
public struct GmailStoreVerifier: Sendable {
    public let account: Account
    let client: GmailClient
    let source: GmailMessageSource
    let budget: ByteBudget
    private let logger = Logger(label: "ee.getstow.sync.verify")

    public init(account: Account, tokens: TokenProvider, source: GmailMessageSource, budget: ByteBudget) {
        self.init(account: account, client: GmailClient(account: account.id, tokens: tokens), source: source, budget: budget)
    }

    init(account: Account, client: GmailClient, source: GmailMessageSource, budget: ByteBudget) {
        self.account = account
        self.client = client
        self.source = source
        self.budget = budget
    }

    /// - Parameter sample: how many archived messages to check, picked at random; nil for all.
    public func run(sample: Int?) async throws -> VerifyReport {
        var generator = SystemRandomNumberGenerator()
        return try await run(sample: sample, using: &generator)
    }

    public func run<G: RandomNumberGenerator>(sample: Int?, using generator: inout G) async throws -> VerifyReport {
        var report = VerifyReport()
        let ids = try await source.listGmailMessageIDs()
        report.storedMessages = ids.count
        var chosen = ids
        if let sample, sample < ids.count {
            chosen = Array(ids.shuffled(using: &generator).prefix(max(0, sample))).sorted()
        }
        report.sampled = chosen.count
        guard !chosen.isEmpty else { return report }

        // Only the digest is kept, so checking every message never holds them all in memory.
        var stored: [UInt64: SHA256.Digest] = [:]
        var plannedBytes: Int64 = 0
        for id in chosen {
            let bytes = try await source.readGmailMessage(id)
            stored[id] = SHA256.hash(data: bytes)
            plannedBytes += Int64(bytes.count)
        }
        guard try await budget.allows(plannedBytes) else {
            throw SyncError.budgetExhausted(usedBytes: try await budget.used(), limitBytes: budget.limit ?? 0)
        }

        for id in chosen {
            let message: GmailMessage
            do {
                message = try await client.message(GmailMessageID(number: id), format: .raw)
            } catch is GmailNotFound {
                report.goneFromServer.append(.gmail(id))
                continue
            } catch SyncError.commandFailed, SyncError.protocolViolation {
                // One unusable reply (seen once on the test account: HTTP 400 failedPrecondition,
                // gone on the next run) is reported as not compared, as over IMAP, not a failed run.
                report.notCompared.append(.gmail(id))
                continue
            }
            let bytes = message.raw ?? Data()
            try await budget.record(Int64(bytes.count))
            report.compared += 1
            if SHA256.hash(data: bytes) == stored[id]! {
                report.identical += 1
            } else {
                report.mismatched.append(.gmail(id))
            }
            // The thread key `g:<id>` (D-205, D-566) depends on IMAP's X-GM-THRID being the API's threadId.
            if let thread = try await source.storedGmailThreadID(id) {
                report.threadIDsCompared += 1
                if message.threadID.number != thread { report.threadIDMismatched.append(.gmail(id)) }
            }
        }
        report.mismatched.sort()
        report.threadIDMismatched.sort()
        report.goneFromServer.sort()
        logger.notice("Verify finished", metadata: [
            "account": "\(account.id)", "sampled": "\(report.sampled)", "compared": "\(report.compared)",
            "mismatched": "\(report.mismatched.count)",
        ])
        return report
    }
}
