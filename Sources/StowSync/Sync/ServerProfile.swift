import Foundation
import StowCore

/// How Stow secures the connection to a server. One choice only: TLS from the
/// first byte (D-570 items 1 and 2). STARTTLS would be a second case, added
/// only by its own decision.
public enum ServerSecurity: String, Sendable, Codable, CaseIterable {
    case tls
}

/// Where an `imap` account's mail lives and the name it signs in with
/// (brief step 1). Not secret: the password is in the Keychain (D-467, D-570).
/// The host and username are personal data like the address, so they are
/// logged only at debug level.
public struct ServerProfile: Sendable, Equatable, Codable {
    /// Lowercased, without a trailing dot.
    public let host: String
    public let port: Int
    public let security: ServerSecurity
    /// The IMAP login name. Asked for separately and defaulting to the
    /// address, but stored, never assumed equal to it.
    public let username: String
    /// The preset this came from, or nil for a server the user typed.
    public let presetID: String?

    /// A server the user typed. Checks the host and port, and that the
    /// username is not empty.
    public init(host: String, port: Int = 993, username: String) throws {
        try self.init(host: host, port: port, security: .tls, username: username, presetID: nil)
    }

    /// A preset's fixed host and port (D-570 item 5: not editable).
    public init(preset: IMAPPreset, username: String) throws {
        try self.init(host: preset.host, port: preset.port, security: .tls, username: username, presetID: preset.id)
    }

    /// For reading back what was stored: checked again, so a damaged row
    /// cannot point Stow somewhere it would not have accepted at add time.
    public init(host: String, port: Int, security: ServerSecurity, username: String, presetID: String?) throws {
        self.host = try Self.checkedHost(host)
        guard (1...65535).contains(port) else { throw ServerProfileError.badPort }
        self.port = port
        self.security = security
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ServerProfileError.badUsername
        }
        self.username = trimmed
        if let presetID, IMAPPreset.withID(presetID) == nil { throw ServerProfileError.unknownPreset(presetID) }
        self.presetID = presetID
    }

    public var endpoint: IMAPEndpoint { IMAPEndpoint(host: host, port: port) }

    public var preset: IMAPPreset? { presetID.flatMap(IMAPPreset.withID) }

    /// A host name or an IPv4 address, nothing else: no scheme, path, port,
    /// user, spaces or non-ASCII (an international name is typed in its
    /// `xn--` form). Lowercased, one trailing dot removed.
    static func checkedHost(_ typed: String) throws -> String {
        var host = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253, host.allSatisfy(\.isASCII) else { throw ServerProfileError.badHost }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard (1...63).contains(label.count), label.allSatisfy(allowed.contains),
                  label.first != "-", label.last != "-" else { throw ServerProfileError.badHost }
        }
        return host
    }
}

/// Why server details were refused before anything was sent (D-082).
public enum ServerProfileError: Error, Equatable, CustomStringConvertible {
    case badHost
    case badPort
    case badUsername
    case unknownPreset(String)

    public var description: String {
        switch self {
        case .badHost:
            "That is not a server name Stow can use. Type just the name, like imap.example.com, without https://, a port or a path. An international name goes in its xn-- form. Nothing was sent."
        case .badPort:
            "The port must be a number from 1 to 65535. For IMAP over TLS it is usually 993. Nothing was sent."
        case .badUsername:
            "The IMAP username is empty or has a control character in it. It is usually your full address. Nothing was sent."
        case .unknownPreset(let id):
            "There is no preset called \"\(id)\". Run `stowmail account add imap --help` for the list, or give the server with --host. Nothing was sent."
        }
    }
}

/// A provider Stow knows the IMAP details of (brief step 1). Each host was
/// checked against the provider's help page (D-576); connection limits stay
/// at the unknown-server default until measured on a real mailbox (brief step 4).
public struct IMAPPreset: Sendable, Equatable {
    public let id: String
    public let name: String
    public let host: String
    public let port: Int
    /// Address domains this preset is suggested for, exactly.
    public let domains: Set<String>
    /// First labels that mark country versions, such as `yahoo` for yahoo.co.uk.
    public let domainFirstLabels: Set<String>
    /// What the provider wants before a mail app can sign in: an app
    /// password, or IMAP turned on. Shown before the password prompt and
    /// when the password is refused. Nil when nothing is needed.
    public let signInAdvice: String?
    /// Most connections at once. 1, the unknown-server default, until measured.
    public let maxConnections: Int

    /// The presets, in the order `--help` lists them. Written from
    /// `docs/imap-providers.md` (D-576), checked 3 November 2026; a change
    /// starts there. Advice holds only facts from the providers' own pages.
    public static let all: [IMAPPreset] = [
        IMAPPreset(id: "fastmail", name: "Fastmail", host: "imap.fastmail.com", port: 993,
                   domains: ["fastmail.com", "fastmail.fm", "fastmail.net", "fastmail.org", "fastmail.uk", "fastmail.co.uk",
                             "fastmail.de", "fastmail.us", "fastmail.com.au", "fastmail.ca", "fastmail.jp", "f-m.fm", "sent.com",
                             "pobox.com", "123mail.org", "airpost.net", "eml.cc", "fastmailbox.net", "imap.cc", "mailbolt.com",
                             "mm.st", "warpmail.net"],
                   domainFirstLabels: [],
                   signInAdvice: "Fastmail needs an app password, not your account password: Settings, Privacy & Security, Connected apps & API tokens, then New app password. IMAP needs a plan above Basic.",
                   maxConnections: 1),
        IMAPPreset(id: "yahoo", name: "Yahoo Mail", host: "imap.mail.yahoo.com", port: 993,
                   domains: ["ymail.com", "rocketmail.com"], domainFirstLabels: ["yahoo"],
                   signInAdvice: "Yahoo needs an app password, not your account password: Account Security, then Generate app password. Yahoo only makes one in a browser that has been signed in for several days, not a private window.",
                   maxConnections: 1),
        IMAPPreset(id: "aol", name: "AOL Mail", host: "imap.aol.com", port: 993,
                   domains: ["aol.com", "aim.com"], domainFirstLabels: [],
                   signInAdvice: "AOL needs an app password, not your account password: Account Security, then Generate app password. AOL only makes one in a browser that has been signed in for several days, not a private window.",
                   maxConnections: 1),
        IMAPPreset(id: "gmx", name: "GMX (gmx.com)", host: "imap.gmx.com", port: 993,
                   domains: ["gmx.com", "gmx.us", "gmx.co.uk", "gmx.fr", "gmx.es"], domainFirstLabels: [],
                   signInAdvice: "GMX needs two things first: IMAP turned on (Email, Settings, POP3 & IMAP), and an app password (Security Options, Manage application-specific passwords). GMX turns IMAP off again after a long time unused.",
                   maxConnections: 1),
        IMAPPreset(id: "gmx-de", name: "GMX (gmx.de and gmx.net)", host: "imap.gmx.net", port: 993,
                   domains: ["gmx.de", "gmx.net", "gmx.at", "gmx.ch"], domainFirstLabels: [],
                   signInAdvice: "GMX needs two things first: IMAP turned on (E-Mail-Einstellungen, POP3/IMAP, POP3- und IMAP-Zugriff erlauben), and an app password (Account verwalten, Login & Sicherheit, App-Passwörter). GMX turns IMAP off again after a long time unused.",
                   maxConnections: 1),
        IMAPPreset(id: "webde", name: "WEB.DE", host: "imap.web.de", port: 993,
                   domains: ["web.de"], domainFirstLabels: [],
                   signInAdvice: "WEB.DE needs two things first: IMAP turned on (E-Mail-Einstellungen, POP3/IMAP), and an App-Passwort (Account verwalten, Login & Sicherheit). WEB.DE turns IMAP off again after a long time unused.",
                   maxConnections: 1),
        IMAPPreset(id: "mailcom", name: "mail.com", host: "imap.mail.com", port: 993,
                   domains: ["mail.com"], domainFirstLabels: [],
                   signInAdvice: "mail.com offers IMAP on Premium only. Turn it on first: Email, Settings, POP3 & IMAP. mail.com turns IMAP off again after a long time unused.",
                   maxConnections: 1),
        IMAPPreset(id: "mailbox-org", name: "mailbox.org", host: "imap.mailbox.org", port: 993,
                   domains: ["mailbox.org"], domainFirstLabels: [],
                   signInAdvice: "mailbox.org works best with an app password, and needs one if two-step verification is on: All settings, Security, Email app-passwords, for IMAP.",
                   maxConnections: 1),
        IMAPPreset(id: "posteo", name: "Posteo", host: "posteo.de", port: 993,
                   domains: ["posteo.de", "posteo.com", "posteo.net", "posteo.us", "posteo.ca", "posteo.uk", "posteo.ie",
                             "posteo.es", "posteo.at", "posteo.ch", "posteo.nl", "posteo.be", "posteo.lu"],
                   domainFirstLabels: [],
                   signInAdvice: "Posteo asks mail apps for an app password (Settings, Password and security), and needs one once its extra account protection is on. The username is your main Posteo address.",
                   maxConnections: 1),
        IMAPPreset(id: "bt", name: "BT Mail", host: "mail.btinternet.com", port: 993,
                   domains: ["btinternet.com", "btopenworld.com"], domainFirstLabels: [],
                   signInAdvice: "BT Mail uses your normal BT email password. If no mail app has signed in for 12 months, BT may switch app access off; resetting the password brings it back.",
                   maxConnections: 1),
        IMAPPreset(id: "orange", name: "Orange", host: "imap.orange.fr", port: 993,
                   domains: ["orange.fr"], domainFirstLabels: [],
                   signInAdvice: "Orange uses your mailbox password. If IMAP was turned off: Mail Orange, Tous les paramètres, Sécurité, Protocoles POP ou IMAP.",
                   maxConnections: 1),
        IMAPPreset(id: "libero", name: "Libero", host: "imapmail.libero.it", port: 993,
                   domains: ["libero.it", "iol.it", "blu.it", "inwind.it"], domainFirstLabels: [],
                   signInAdvice: nil, maxConnections: 1),
    ]

    public static func withID(_ id: String) -> IMAPPreset? {
        all.first { $0.id == id.lowercased() }
    }

    /// The preset for an address's domain, if there is exactly one.
    public static func forDomain(_ domain: String) -> IMAPPreset? {
        let domain = domain.lowercased()
        let firstLabel = domain.split(separator: ".").first.map(String.init) ?? ""
        return all.first { $0.domains.contains(domain) } ?? all.first { $0.domainFirstLabels.contains(firstLabel) }
    }
}
