import Foundation

/// Splits a folder's messages into download batches (D-105).
///
/// A batch holds at most `maxMessages` messages and, where possible, at most
/// `maxBytes` bytes. A single message bigger than `maxBytes` gets a batch of
/// its own, so nothing is ever left out.
public struct BatchPlanner: Sendable, Equatable {
    public var maxMessages: Int
    public var maxBytes: Int

    public init(maxMessages: Int = 100, maxBytes: Int = 25_000_000) {
        precondition(maxMessages > 0 && maxBytes > 0)
        self.maxMessages = maxMessages
        self.maxBytes = maxBytes
    }

    public func batches(_ messages: [MessageSummary]) -> [[MessageSummary]] {
        var result: [[MessageSummary]] = []
        var current: [MessageSummary] = []
        var currentBytes = 0
        for message in messages {
            let wouldOverflow = !current.isEmpty
                && (current.count >= maxMessages || currentBytes + message.size > maxBytes)
            if wouldOverflow {
                result.append(current)
                current = []
                currentBytes = 0
            }
            current.append(message)
            currentBytes += message.size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
