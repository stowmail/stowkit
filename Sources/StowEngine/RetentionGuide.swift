import Foundation
import StowCore

/// The provider-specific steps for deleting old mail from the server, offered
/// once the coverage date covers the whole range (D-021, D-024, D-034). Stow
/// itself never deletes from a mailbox. Draft wording; the app's version lives
/// in `docs/ui-notes/retention-and-deleting-from-gmail.md`.
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

    /// Step-by-step instructions to delete mail received before `before`.
    public static func steps(_ kind: MailboxKind, before: Date) -> [String] {
        let day = Self.day(before)
        switch kind {
        case .gmail:
            return [
                "In Gmail on the web, turn off Conversation view first (Settings, See all settings, General, Conversation view off, Save). Otherwise deleting an old conversation also deletes newer replies in it, which may not be archived yet.",
                "Search for: before:\(day.replacingOccurrences(of: "-", with: "/"))",
                "Tick the box to select all, then click \"Select all conversations that match this search\".",
                "Click Delete. The messages go to the Bin, where Gmail deletes them after 30 days; empty the Bin to free the space now.",
                "Turn Conversation view back on if you use it.",
            ]
        case .googleWorkspace:
            return [
                "A Google Workspace administrator can set Gmail to delete mail older than a set age (Admin console, Apps, Google Workspace, Gmail, Compliance, Email and chat auto-deletion). It applies to everyone in the organisation, so agree it first.",
                "Or delete it yourself as for personal Gmail: turn off Conversation view, search for before:\(day.replacingOccurrences(of: "-", with: "/")), select all matching conversations and delete them.",
            ]
        case .microsoft365:
            return [
                "Your Microsoft 365 administrator can apply a retention policy that deletes mail older than a set age (Microsoft Purview). Ask them before changing anything.",
                "Or in Outlook on the web, search for received:<\(day), select the results and delete them, then empty Deleted Items.",
            ]
        case .outlookCom:
            return [
                "In Outlook.com, search for received:<\(day), select all results and delete them.",
                "Empty Deleted Items to free the space now.",
            ]
        }
    }

    /// The one line of warning above the steps (D-024): Stow will hold the only copy.
    public static func warning(count: Int, bytes: Int, lastBackup: Date?, now: Date = Date()) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let base = "After you delete this, Stow will hold the only copy of these \(count) emails (\(size))."
        guard let lastBackup else {
            return base + " Make sure this Mac is backed up and your recovery key is saved."
        }
        let days = Int(now.timeIntervalSince(lastBackup) / 86_400)
        if days >= 7 { return base + " Time Machine has not backed up for \(days) days. Back up first, and make sure your recovery key is saved." }
        return base + " Backed up by Time Machine \(days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"). Make sure your recovery key is saved."
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
