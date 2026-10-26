import Foundation
import StowCore

/// The provider-specific steps for deleting old mail from the server, offered
/// once the coverage date covers the whole range (D-021, D-024, D-034). Stow
/// itself never deletes from a mailbox. The steps' wording is the app's, from
/// `docs/ui-notes/retention-and-deleting-from-gmail.md`.
public enum RetentionGuide {
    public enum MailboxKind: Sendable, Equatable {
        case gmail
        case googleWorkspace
        case microsoft365
        case outlookCom
    }

    static let consumerGoogle: Set<String> = ["gmail.com", "googlemail.com"]
    static let consumerMicrosoft: Set<String> = [
        "outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.co.uk", "hotmail.co.uk", "live.co.uk",
    ]

    public static func kind(provider: Provider, email: String) -> MailboxKind {
        let domain = EmailAddress(address: email).domain
        switch provider {
        case .gmail: return consumerGoogle.contains(domain) ? .gmail : .googleWorkspace
        case .microsoft: return consumerMicrosoft.contains(domain) ? .outlookCom : .microsoft365
        }
    }

    /// One step of the instructions. `search` is the text to type into the provider's search,
    /// shown on its own with a Copy button in the app, after `text` in the CLI.
    public struct Step: Sendable, Equatable {
        public var text: String
        public var search: String?

        public init(_ text: String, search: String? = nil) {
            self.text = text
            self.search = search
        }

        /// The step as one line.
        public var line: String { search.map { "\(text) \($0)" } ?? text }
    }

    /// What to type into the provider's search to find mail received before `before`:
    /// `before:2025/10/13` in Gmail, `received:<2025-10-13` in Outlook.
    public static func search(_ kind: MailboxKind, before: Date) -> String {
        let day = Self.day(before)
        switch kind {
        case .gmail, .googleWorkspace: return "before:\(day.replacingOccurrences(of: "-", with: "/"))"
        case .microsoft365, .outlookCom: return "received:<\(day)"
        }
    }

    /// Step-by-step instructions to delete mail received before `before`. The wording is the
    /// app's, from `docs/ui-notes/retention-and-deleting-from-gmail.md`.
    public static func guide(_ kind: MailboxKind, before: Date) -> [Step] {
        let search = search(kind, before: before)
        switch kind {
        case .gmail:
            return [
                Step("Open Gmail on the web and turn off Conversation view (Settings, See all settings, General). Otherwise deleting an old conversation also deletes newer replies in it."),
                Step("Search for:", search: search),
                Step("Select all, then \"Select all conversations that match this search\"."),
                Step("Delete. To get the space back straight away, empty Bin."),
                Step("Turn Conversation view back on if you use it."),
            ]
        case .googleWorkspace:
            return [
                Step("Open Gmail on the web and turn off Conversation view (Settings, See all settings, General). Otherwise deleting an old conversation also deletes newer replies in it."),
                Step("Search for:", search: search),
                Step("Select all, then \"Select all conversations that match this search\"."),
                Step("Delete. To get the space back straight away, empty Bin."),
                Step("Turn Conversation view back on if you use it."),
                Step("Or ask your Google Workspace administrator to set Gmail to delete mail after a set age (Email and chat auto-deletion). It applies to everyone in your organisation."),
            ]
        case .microsoft365:
            return [
                Step("Open Outlook on the web and search for:", search: search),
                Step("Select all the results and delete them."),
                Step("Empty Deleted Items to get the space back straight away."),
                Step("Or ask your Microsoft 365 administrator for a retention policy that deletes mail after a set age. Ask before changing anything."),
            ]
        case .outlookCom:
            return [
                Step("Open Outlook.com and search for:", search: search),
                Step("Select all the results and delete them."),
                Step("Empty Deleted Items to get the space back straight away."),
            ]
        }
    }

    /// The same steps as lines, for the CLI.
    public static func steps(_ kind: MailboxKind, before: Date) -> [String] {
        guide(kind, before: before).map(\.line)
    }

    /// What Time Machine says, for the line above the steps (D-024).
    public enum Backup: Sendable, Equatable {
        /// Stow cannot read Time Machine's status (not set up, or `tmutil` not allowed).
        case unknown
        /// The last backup finished this many whole days ago, under a week.
        case recent(daysAgo: Int)
        /// No backup for a week or more.
        case overdue(days: Int)
    }

    /// A week or more without a backup is worth saying.
    public static let overdueDays = 7

    public static func backup(lastBackup: Date?, now: Date = Date()) -> Backup {
        guard let lastBackup else { return .unknown }
        let days = max(0, Int(now.timeIntervalSince(lastBackup) / 86_400))
        return days >= overdueDays ? .overdue(days: days) : .recent(daysAgo: days)
    }

    /// The one line of warning above the steps (D-024): Stow will hold the only copy.
    public static func warning(count: Int, bytes: Int, lastBackup: Date?, now: Date = Date()) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let base = "After you delete this, Stow will hold the only copy of these \(count) emails (\(size))."
        switch backup(lastBackup: lastBackup, now: now) {
        case .unknown:
            return base + " Make sure this Mac is backed up and your recovery key is saved."
        case .overdue(let days):
            return base + " Time Machine has not backed up for \(days) days. Back up first, and make sure your recovery key is saved."
        case .recent(let days):
            return base + " Backed up by Time Machine \(days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"). Make sure your recovery key is saved."
        }
    }

    /// `YYYY-MM-DD` in UTC.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// When Time Machine last finished a backup, if `tmutil` will say (D-024).
public enum TimeMachineStatus {
    public static func latestBackup() -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["latestbackup"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(output)
    }

    /// Backups are named by date and time, for example `.../2026-10-22-103000` or `2026-10-22-103000.backup`.
    static func parse(_ output: String) -> Date? {
        guard let match = output.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(output[match]))
    }
}
