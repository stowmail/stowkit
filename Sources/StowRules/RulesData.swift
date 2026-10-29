import Foundation
import StowCore

/// Why the protection lists could not be used (A-19, D-517).
public enum RulesDataProblem: Error, Hashable, Sendable, CustomStringConvertible {
    case missing
    case unreadable
    /// The named list is empty in the file.
    case emptyList(String)

    /// What `stowmail rules`, `doctor` and Tidy up show.
    public static let message = "Stow could not read its list of protected senders, so it is not suggesting anything to remove. Reinstall Stow to fix this."

    public var description: String {
        switch self {
        case .missing: "\(Self.message) (rules-data.json is missing.)"
        case .unreadable: "\(Self.message) (rules-data.json could not be read.)"
        case .emptyList(let name): "\(Self.message) (rules-data.json has an empty \(name) list.)"
        }
    }
}

/// The plain data behind the sender signals and protected mail, loaded from `Resources/rules-data.json`.
///
/// Fails closed (A-19, D-517): if the file is missing, does not decode, lacks a
/// list or has an empty one, `loadProblem` says so and the lists are empty, and
/// `RuleSet.assess` then suggests nothing for removal at all.
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
    /// Set when the data could not be loaded; never encoded.
    public var loadProblem: RulesDataProblem?

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

    /// Every list is required: a missing one is an error, not an empty list (A-19).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        noReplyLocalParts = try c.decode([String].self, forKey: .noReplyLocalParts)
        listProviderDomains = try c.decode([String].self, forKey: .listProviderDomains)
        protectedSubjectKeywords = try c.decode([String].self, forKey: .protectedSubjectKeywords)
        protectedSenderKeywords = try c.decode([String].self, forKey: .protectedSenderKeywords)
        billingSenders = try c.decode([String].self, forKey: .billingSenders)
    }

    /// Lists with nothing in them, by their name in the file.
    var emptyLists: [String] {
        [("noReplyLocalParts", noReplyLocalParts), ("listProviderDomains", listProviderDomains),
         ("protectedSubjectKeywords", protectedSubjectKeywords), ("protectedSenderKeywords", protectedSenderKeywords),
         ("billingSenders", billingSenders)].filter { $0.1.isEmpty }.map(\.0)
    }

    /// Empty lists carrying `problem`: what a failed load gives.
    public static func unusable(_ problem: RulesDataProblem) -> RulesData {
        var data = RulesData(noReplyLocalParts: [], listProviderDomains: [])
        data.loadProblem = problem
        return data
    }

    /// Loads and checks a data file. Never throws: a problem is carried in `loadProblem`.
    public static func load(from url: URL?) -> RulesData {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return .unusable(.missing) }
        guard let bytes = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(RulesData.self, from: bytes) else {
            return .unusable(.unreadable)
        }
        if let empty = decoded.emptyLists.first { return .unusable(.emptyList(empty)) }
        return decoded
    }

    /// The data file shipped with the package. A missing or broken file is a
    /// packaging bug; it never crashes, and it never lets protected mail be
    /// suggested for removal: check `loadProblem`.
    public static let bundled: RulesData = load(from: Bundle.module.url(forResource: "rules-data", withExtension: "json"))

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
