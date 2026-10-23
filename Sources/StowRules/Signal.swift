import Foundation
import StowCore

/// Stable identifier for each bulk-mail signal. Raw values are written to the settings file.
public enum SignalID: String, Codable, CaseIterable, Sendable {
    case listUnsubscribe
    case precedenceBulk
    case userNotInTo
    case recipientCount
    case senderNoReply
    case senderListProvider
    case replyToDiffers
}

/// How much a signal says on its own. "Consider deleting from source" needs two strong ones.
public enum SignalStrength: String, Codable, Sendable {
    case strong
    case weak
}

/// What one signal found in one message. `reason` is plain English and is shown to the user.
public struct SignalResult: Hashable, Sendable {
    public var id: SignalID
    public var fired: Bool
    public var reason: String

    public init(id: SignalID, fired: Bool, reason: String) {
        self.id = id
        self.fired = fired
        self.reason = reason
    }
}

/// Everything a signal may look at besides the headers.
public struct SignalContext: Sendable {
    /// The account's own addresses, normalised (lowercase, trimmed).
    public var ownAddresses: Set<String>
    public var recipientThreshold: Int
    public var data: RulesData

    public init(ownAddresses: Set<String> = [], recipientThreshold: Int = 20, data: RulesData = .bundled) {
        self.ownAddresses = Set(ownAddresses.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        self.recipientThreshold = recipientThreshold
        self.data = data
    }
}

/// A signal is a pure function from headers (and the context) to a result with a reason.
/// It reads nothing else: no network, no storage, no logging.
public protocol Signal: Sendable {
    var id: SignalID { get }
    var title: String { get }
    var strength: SignalStrength { get }
    func evaluate(_ headers: MessageHeaders, context: SignalContext) -> SignalResult
}

extension Signal {
    func result(_ fired: Bool, _ reason: String) -> SignalResult {
        SignalResult(id: id, fired: fired, reason: reason)
    }
}
