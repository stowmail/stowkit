import Foundation
import StowCore

/// The plain data behind the sender signals and protected mail, loaded from `Resources/rules-data.json`.
public struct RulesData: Codable, Hashable, Sendable {
    public var version: Int
    public var noReplyLocalParts: [String]
    public var listProviderDomains: [String]
    /// Words that protect a message when its subject contains one as a whole word (UI-10, D-407).
    public var protectedSubjectKeywords: [String]
    /// Words that protect a message when its sender's local part contains one,
    /// between dots, dashes, underscores or `+` (`invoices@`, `billing-noreply@`).
    public var protectedSenderKeywords: [String]
    /// Known billing senders: a full address, or a domain (that domain only, as overrides match).
    public var billingSenders: [String]

    public init(version: Int = 2, noReplyLocalParts: [String], listProviderDomains: [String],
                protectedSubjectKeywords: [String] = [], protectedSenderKeywords: [String] = [], billingSenders: [String] = []) {
        self.version = version
        self.noReplyLocalParts = noReplyLocalParts
        self.listProviderDomains = listProviderDomains
        self.protectedSubjectKeywords = protectedSubjectKeywords
        self.protectedSenderKeywords = protectedSenderKeywords
        self.billingSenders = billingSenders
    }

    enum CodingKeys: String, CodingKey {
        case version, noReplyLocalParts, listProviderDomains, protectedSubjectKeywords, protectedSenderKeywords, billingSenders
    }

    /// The protection lists are optional in the file, so a version 1 file still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        noReplyLocalParts = try c.decode([String].self, forKey: .noReplyLocalParts)
        listProviderDomains = try c.decode([String].self, forKey: .listProviderDomains)
        protectedSubjectKeywords = try c.decodeIfPresent([String].self, forKey: .protectedSubjectKeywords) ?? []
        protectedSenderKeywords = try c.decodeIfPresent([String].self, forKey: .protectedSenderKeywords) ?? []
        billingSenders = try c.decodeIfPresent([String].self, forKey: .billingSenders) ?? []
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

    /// The first protected subject keyword the subject holds as a whole word, ignoring case.
    public func protectedSubjectKeyword(in subject: String) -> String? {
        let words = Set(Self.words(subject))
        return protectedSubjectKeywords.first { words.contains($0.lowercased()) }
    }

    /// The first protected sender keyword among the local part's pieces.
    public func protectedSenderKeyword(inLocalPart localPart: String) -> String? {
        let pieces = Set(Self.words(localPart))
        return protectedSenderKeywords.first { pieces.contains($0.lowercased()) }
    }

    /// The listed billing sender that `sender` matches: its address, or its exact domain.
    public func billingSender(_ sender: EmailAddress) -> String? {
        billingSenders.first { entry in
            let match = entry.lowercased()
            return match.contains("@") ? sender.normalised == match : sender.domain == match
        }
    }

    /// Lowercased runs of letters and digits.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
