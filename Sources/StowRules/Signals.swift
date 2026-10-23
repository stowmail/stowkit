import Foundation
import StowCore

/// `List-Unsubscribe` present: the sender is a mailing list or campaign.
public struct ListUnsubscribeSignal: Signal {
    public let id = SignalID.listUnsubscribe
    public let title = "Has an unsubscribe header"
    public let strength = SignalStrength.strong
    public init() {}

    public func evaluate(_ headers: MessageHeaders, context: SignalContext) -> SignalResult {
        let value = headers.listUnsubscribe?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty
            ? result(false, "No List-Unsubscribe header.")
            : result(true, "Has a List-Unsubscribe header, which mailing lists and campaigns add.")
    }
}

/// `Precedence: bulk`, `list` (or the older `junk`).
public struct PrecedenceBulkSignal: Signal {
    public let id = SignalID.precedenceBulk
    public let title = "Marked as bulk or list mail"
    public let strength = SignalStrength.strong
    public init() {}

    public func evaluate(_ headers: MessageHeaders, context: SignalContext) -> SignalResult {
        let value = (headers.precedence ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if ["bulk", "list", "junk"].contains(value) {
            return result(true, "Sent with Precedence: \(value), which senders use to mark bulk mail.")
        }
        return result(false, "No bulk or list Precedence header.")
    }
}

/// The user is a recipient but not in To: only copied, blind-copied or delivered via a list or alias.
public struct UserNotInToSignal: Signal {
    public let id = SignalID.userNotInTo
    public let title = "You are not a direct recipient"
    public let strength = SignalStrength.weak
    public init() {}

    public func evaluate(_ headers: MessageHeaders, context: SignalContext) -> SignalResult {
        guard !context.ownAddresses.isEmpty else {
            return result(false, "Your own addresses are not known, so this could not be checked.")
        }
        let own = context.ownAddresses
        func contains(_ list: [EmailAddress]) -> Bool { list.contains { own.contains($0.normalised) } }
        if contains(headers.to) {
            return result(false, "You are listed in To.")
        }
        if contains(headers.cc) {
            return result(true, "You are only copied (Cc), not addressed directly.")
        }
        if contains(headers.bcc) {
            return result(true, "You are only blind-copied (Bcc), not addressed directly.")
        }
        if contains(headers.deliveredTo) {
            return result(true, "You are not named in To or Cc: the message reached you without your address in the visible recipients, as bulk mail and blind copies do.")
        }
        return result(false, "None of your addresses appear in the recipient headers.")
    }
}

/// Many recipients. Threshold comes from the context (default 20).
public struct RecipientCountSignal: Signal {
    public let id = SignalID.recipientCount
    public let title = "Sent to many recipients"
    public let strength = SignalStrength.weak
    public init() {}

    public func evaluate(_ headers: MessageHeaders, context: SignalContext) -> SignalResult {
        let count = headers.recipientCount
        let limit = context.recipientThreshold
        return count >= limit
            ? result(true, "Sent to \(count) recipients, at or above the limit of \(limit).")
            : result(false, "Sent to \(count) recipients, below the limit of \(limit).")
    }
}

/// Sender local part looks like no-reply.
public struct SenderNoReplySignal: Signal {
    public let id = SignalID.senderNoReply
    public let title = "Sent from a no-reply address"
    public let strength = SignalStrength.weak
    public init() {}

    public func evaluate(_ headers: MessageHeaders, context: SignalContext) -> SignalResult {
        guard let from = headers.from.first else {
            return result(false, "No sender address.")
        }
        return context.data.isNoReply(localPart: from.localPart)
            ? result(true, "The sender's address is a no-reply address, so nobody reads replies.")
            : result(false, "The sender's address is not a no-reply address.")
    }
}

/// Sender (From, Sender or the envelope Return-Path) is on a known mass-mailing provider's domain.
public struct SenderListProviderSignal: Signal {
    public let id = SignalID.senderListProvider
    public let title = "Sent through a bulk-mail service"
    public let strength = SignalStrength.strong
    public init() {}

    public func evaluate(_ headers: MessageHeaders, context: SignalContext) -> SignalResult {
        var candidates: [(String, String)] = []
        if let from = headers.from.first { candidates.append(("From", from.domain)) }
        if let sender = headers.sender { candidates.append(("Sender", sender.domain)) }
        if let path = headers.value(named: "Return-Path") {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
            if let at = trimmed.lastIndex(of: "@") {
                candidates.append(("Return-Path", String(trimmed[trimmed.index(after: at)...]).lowercased()))
            }
        }
        for (label, domain) in candidates where context.data.isListProvider(domain) {
            return result(true, "The \(label) domain (\(domain)) belongs to a known bulk-mail service.")
        }
        return result(false, "The sender is not on a known bulk-mail service.")
    }
}

/// Reply-To points to a different domain from From.
public struct ReplyToDiffersSignal: Signal {
    public let id = SignalID.replyToDiffers
    public let title = "Replies go to a different domain"
    public let strength = SignalStrength.weak
    public init() {}

    public func evaluate(_ headers: MessageHeaders, context: SignalContext) -> SignalResult {
        guard let from = headers.from.first, let reply = headers.replyTo.first else {
            return result(false, "No separate Reply-To address.")
        }
        guard !from.domain.isEmpty, !reply.domain.isEmpty else {
            return result(false, "Sender or Reply-To has no domain.")
        }
        return from.domain != reply.domain
            ? result(true, "Replies go to \(reply.domain), not \(from.domain), as with campaign tools.")
            : result(false, "Reply-To is on the same domain as the sender.")
    }
}

public enum Signals {
    /// Every signal, in display order.
    public static let all: [any Signal] = [
        ListUnsubscribeSignal(), PrecedenceBulkSignal(), SenderListProviderSignal(),
        SenderNoReplySignal(), UserNotInToSignal(), RecipientCountSignal(), ReplyToDiffersSignal(),
    ]

    public static func signal(_ id: SignalID) -> any Signal {
        all.first { $0.id == id }!
    }
}
