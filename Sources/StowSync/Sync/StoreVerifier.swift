import CryptoKit
import Foundation
import Logging
import StowCore

/// One stored message, named without anything personal: the folder by its
/// index in the sorted list of the account's stored folders, then UIDVALIDITY
/// and UID (which together are the file's path in the store).
public struct VerifyItem: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var folderIndex: Int
    public var uidValidity: UInt32
    public var uid: UInt32

    public static func < (a: VerifyItem, b: VerifyItem) -> Bool {
        (a.folderIndex, a.uidValidity, a.uid) < (b.folderIndex, b.uidValidity, b.uid)
    }

    public var description: String { "folder \(folderIndex + 1), UIDVALIDITY \(uidValidity), UID \(uid)" }
}

/// What `stowmail verify` found. Numbers and `VerifyItem`s only.
public struct VerifyReport: Sendable, Equatable {
    public var storedMessages = 0
    public var sampled = 0
    /// Stored file length differs from the RFC822.SIZE saved with it.
    public var localSizeMismatches: [VerifyItem] = []
    /// Re-fetched and compared.
    public var compared = 0
    public var identical = 0
    /// Server bytes and stored bytes have different SHA-256s.
    public var mismatched: [VerifyItem] = []
    /// No longer on the server (deleted since it was synced).
    public var goneFromServer: [VerifyItem] = []
    /// Still listed but not returned, or failed the size check, so not compared.
    public var notCompared: [VerifyItem] = []
    /// Folders not checked, with why (folder gone, or UIDVALIDITY changed).
    public var skippedFolders: [Int: String] = [:]

    public var isClean: Bool { mismatched.isEmpty && localSizeMismatches.isEmpty }
}

/// Re-fetches stored messages read-only and checks they are byte-for-byte what
/// the server holds (D-121). Writes nothing to the store; downloads count
/// against the account's byte budget.
public struct StoreVerifier: Sendable {
    public let account: Account
    let openSession: @Sendable () async throws -> IMAPSession
    let source: RawMessageSource
    let budget: ByteBudget
    let chunkSize: Int
    private let logger = Logger(label: "uk.getstow.sync.verify")

    public init(
        account: Account,
        openSession: @escaping @Sendable () async throws -> IMAPSession,
        source: RawMessageSource,
        budget: ByteBudget,
        chunkSize: Int = 20
    ) {
        self.account = account
        self.openSession = openSession
        self.source = source
        self.budget = budget
        self.chunkSize = max(1, chunkSize)
    }

    /// - Parameter sample: how many stored messages to check, picked at random; nil for all.
    public func run(sample: Int?) async throws -> VerifyReport {
        var generator = SystemRandomNumberGenerator()
        return try await run(sample: sample, using: &generator)
    }

    public func run<G: RandomNumberGenerator>(sample: Int?, using generator: inout G) async throws -> VerifyReport {
        var report = VerifyReport()
        let keys = try await source.listKeys().filter { $0.accountID == account.id }
        report.storedMessages = keys.count
        let folderNames = Array(Set(keys.map(\.folder))).sorted()
        let index = Dictionary(uniqueKeysWithValues: folderNames.enumerated().map { ($1, $0) })
        func item(_ key: RawMessageKey) -> VerifyItem {
            VerifyItem(folderIndex: index[key.folder]!, uidValidity: key.uidValidity, uid: key.uid)
        }

        var chosen = keys
        if let sample, sample < keys.count {
            chosen = Array(keys.shuffled(using: &generator).prefix(max(0, sample)))
        }
        report.sampled = chosen.count
        guard !chosen.isEmpty else { return report }

        // Local check first: the file must be as long as the size saved with it.
        // Only the digest is kept, so checking every message never holds them all in memory.
        var stored: [RawMessageKey: SHA256.Digest] = [:]
        var plannedBytes: Int64 = 0
        for key in chosen {
            let message = try await source.read(key)
            if message.bytes.count != message.size { report.localSizeMismatches.append(item(key)) }
            stored[key] = SHA256.hash(data: message.bytes)
            plannedBytes += Int64(message.size)
        }
        guard await budget.allows(plannedBytes) else {
            throw SyncError.budgetExhausted(usedBytes: await budget.used(), limitBytes: budget.limit ?? 0)
        }

        let session = try await openSession()
        do {
            let folders = Dictionary(try await session.listFolders().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let groups = Dictionary(grouping: chosen) { $0.folder }
            for name in groups.keys.sorted() {
                let folderIndex = index[name]!
                guard let folder = folders[name], folder.isSelectable else {
                    report.skippedFolders[folderIndex] = "folder is no longer on the server"
                    continue
                }
                let status = try await session.examine(folder)
                let byValidity = Dictionary(grouping: groups[name]!) { $0.uidValidity }
                for (validity, keys) in byValidity.sorted(by: { $0.key < $1.key }) {
                    guard validity == status.uidValidity else {
                        report.skippedFolders[folderIndex] = "UIDVALIDITY changed since these were stored"
                        continue
                    }
                    let byUID = Dictionary(uniqueKeysWithValues: keys.map { ($0.uid, $0) })
                    let uids = byUID.keys.sorted()
                    for start in stride(from: 0, to: uids.count, by: chunkSize) {
                        let chunk = Array(uids[start..<min(start + chunkSize, uids.count)])
                        let reply = try await session.fetchMessagesWithDiagnostics(uids: chunk, gmail: false)
                        var bytes: Int64 = 0
                        var answered: Set<UInt32> = []
                        for message in reply.messages {
                            guard let key = byUID[message.uid] else { continue }
                            answered.insert(message.uid)
                            bytes += Int64(message.bytes.count)
                            guard message.sizeMatches else { report.notCompared.append(item(key)); continue }
                            report.compared += 1
                            if SHA256.hash(data: message.bytes) == stored[key]! {
                                report.identical += 1
                            } else {
                                report.mismatched.append(item(key))
                            }
                        }
                        try await budget.record(bytes)
                        let unanswered = chunk.filter { !answered.contains($0) }
                        if !unanswered.isEmpty {
                            let stillThere = Set(try await session.fetchUIDs(unanswered).map(\.uid))
                            for uid in unanswered {
                                if stillThere.contains(uid) {
                                    report.notCompared.append(item(byUID[uid]!))
                                } else {
                                    report.goneFromServer.append(item(byUID[uid]!))
                                }
                            }
                        }
                    }
                }
            }
            await session.logout()
        } catch {
            await session.disconnect()
            throw error
        }
        report.mismatched.sort()
        report.localSizeMismatches.sort()
        report.goneFromServer.sort()
        report.notCompared.sort()
        logger.notice("Verify finished", metadata: [
            "account": "\(account.id)", "sampled": "\(report.sampled)", "compared": "\(report.compared)",
            "mismatched": "\(report.mismatched.count)", "localSizeMismatches": "\(report.localSizeMismatches.count)",
        ])
        return report
    }
}
