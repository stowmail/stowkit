import Foundation

/// The plain data behind the sender signals, loaded from `Resources/rules-data.json`.
public struct RulesData: Codable, Hashable, Sendable {
    public var version: Int
    public var noReplyLocalParts: [String]
    public var listProviderDomains: [String]

    public init(version: Int = 1, noReplyLocalParts: [String], listProviderDomains: [String]) {
        self.version = version
        self.noReplyLocalParts = noReplyLocalParts
        self.listProviderDomains = listProviderDomains
    }

    /// The data file shipped with the package. A missing or broken file is a packaging bug,
    /// so it degrades to empty lists (those two signals never fire) rather than crashing.
    public static let bundled: RulesData = {
        guard let url = Bundle.module.url(forResource: "rules-data", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RulesData.self, from: data)
        else { return RulesData(noReplyLocalParts: [], listProviderDomains: []) }
        return decoded
    }()

    /// True when `domain` is a listed provider domain or a subdomain of one.
    public func isListProvider(_ domain: String) -> Bool {
        let d = domain.lowercased()
        guard !d.isEmpty else { return false }
        return listProviderDomains.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    /// True when the local part, ignoring dots, dashes and underscores, starts with a no-reply pattern.
    /// "No-Reply", "no_reply" and "noreply+abc" all match; "reply" and "norman" do not.
    public func isNoReply(localPart: String) -> Bool {
        let stripped = localPart.lowercased().filter { $0 != "-" && $0 != "_" && $0 != "." }
        return noReplyLocalParts.contains { stripped.hasPrefix($0) }
    }
}
