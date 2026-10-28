import Foundation
import StowCore

/// Which folders a sync downloads, and why the others are left out (D-104).
public struct FolderPlan: Sendable {
    public struct Skipped: Sendable {
        public let folder: IMAPFolder
        public let reason: String
    }

    public var toSync: [IMAPFolder]
    public var skipped: [Skipped]
}

public enum FolderPlanner {
    /// - Gmail: only the folder flagged `\All` (All Mail, whose name is
    ///   localised). Every other label is a view onto All Mail, and the labels
    ///   arrive with each message. Spam and Bin are not in All Mail and are not synced.
    /// - Microsoft: every selectable folder except Junk (`\Junk`). Deleted
    ///   Items is kept, because Exchange does not empty it by default and
    ///   people often treat it as storage. Exchange's non-mail folders
    ///   (Calendar, Contacts, Journal, Notes, Tasks, Conversation History,
    ///   Outbox) are skipped (D-112).
    /// - iCloud: every selectable folder except Junk and Deleted Messages,
    ///   found by SPECIAL-USE flag, by name only when no folder has the flag.
    ///   iCloud erases Deleted Messages after 30 days, as Gmail does Bin, so
    ///   it is skipped for the same reason (D-104, D-469).
    public static func plan(provider: Provider, folders: [IMAPFolder], capabilities: Set<String>) throws -> FolderPlan {
        switch provider {
        case .gmail: try planGmail(folders: folders, capabilities: capabilities)
        case .microsoft: planMicrosoft(folders: folders)
        case .icloud: planICloud(folders: folders)
        }
    }

    static func planGmail(folders: [IMAPFolder], capabilities: Set<String>) throws -> FolderPlan {
        guard capabilities.contains("X-GM-EXT-1") else {
            throw SyncError.protocolViolation("This server does not offer Gmail's IMAP extensions (X-GM-EXT-1)")
        }
        guard let allMail = folders.first(where: { $0.has("\\All") && $0.isSelectable }) else {
            throw SyncError.allMailNotFound
        }
        var skipped: [FolderPlan.Skipped] = []
        for folder in folders where folder != allMail {
            let reason: String
            if !folder.isSelectable {
                reason = "cannot be opened (\\Noselect)"
            } else if folder.has("\\Junk") {
                reason = "Spam: not in All Mail, not archived (D-104)"
            } else if folder.has("\\Trash") {
                reason = "Bin: not in All Mail, not archived (D-104)"
            } else {
                reason = "label: its messages come from All Mail, with labels attached"
            }
            skipped.append(.init(folder: folder, reason: reason))
        }
        return FolderPlan(toSync: [allMail], skipped: skipped)
    }

    /// Exchange's built-in folders that hold calendar items, contacts and so on
    /// rather than mail (D-112). Matched on the top-level name only, with all
    /// their subfolders, so a user folder such as "Work/Calendar" or
    /// "Calendar invites" is still synced. Exchange creates these at the top
    /// level, so a user cannot make a mail folder with the same top-level name.
    static let exchangeNonMailFolders: Set<String> = [
        "calendar", "contacts", "journal", "notes", "tasks", "conversation history", "outbox",
    ]

    /// Attributes some servers use for the same folders. Exchange does not
    /// currently send them, but they are honoured first if it ever does.
    static let nonMailAttributes: Set<String> = ["\\calendar", "\\contacts", "\\tasks", "\\notes", "\\journal", "\\outbox"]

    static func nonMailReason(_ folder: IMAPFolder) -> String? {
        if let attribute = folder.attributes.first(where: nonMailAttributes.contains) {
            return "not mail (\(attribute) folder, D-112)"
        }
        let topLevel: Substring
        if let separator = folder.separator {
            topLevel = folder.name.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        } else {
            topLevel = Substring(folder.name)
        }
        guard exchangeNonMailFolders.contains(topLevel.lowercased()) else { return nil }
        return "not mail (Exchange \(topLevel) folder, D-112)"
    }

    static func planMicrosoft(folders: [IMAPFolder]) -> FolderPlan {
        var plan = FolderPlan(toSync: [], skipped: [])
        for folder in folders {
            if !folder.isSelectable {
                plan.skipped.append(.init(folder: folder, reason: "cannot be opened (\\Noselect)"))
            } else if let reason = nonMailReason(folder) {
                plan.skipped.append(.init(folder: folder, reason: reason))
            } else if folder.has("\\Junk") {
                plan.skipped.append(.init(folder: folder, reason: "Junk: not archived (D-104)"))
            } else {
                plan.toSync.append(folder)
            }
        }
        return plan
    }

    /// iCloud's names for its Junk and Deleted Messages folders, used only
    /// when no folder carries the SPECIAL-USE flag (D-469).
    static let icloudJunkName = "Junk"
    static let icloudTrashName = "Deleted Messages"

    static func planICloud(folders: [IMAPFolder]) -> FolderPlan {
        let flagsJunk = folders.contains { $0.has("\\Junk") }
        let flagsTrash = folders.contains { $0.has("\\Trash") }
        func isJunk(_ folder: IMAPFolder) -> Bool {
            flagsJunk ? folder.has("\\Junk") : folder.name.caseInsensitiveCompare(icloudJunkName) == .orderedSame
        }
        func isTrash(_ folder: IMAPFolder) -> Bool {
            flagsTrash ? folder.has("\\Trash") : folder.name.caseInsensitiveCompare(icloudTrashName) == .orderedSame
        }
        var plan = FolderPlan(toSync: [], skipped: [])
        for folder in folders {
            if !folder.isSelectable {
                plan.skipped.append(.init(folder: folder, reason: "cannot be opened (\\Noselect)"))
            } else if isJunk(folder) {
                plan.skipped.append(.init(folder: folder, reason: "Junk: not archived (D-104)"))
            } else if isTrash(folder) {
                plan.skipped.append(.init(folder: folder, reason: "Deleted Messages: iCloud erases it after 30 days, not archived (D-104, D-469)"))
            } else {
                plan.toSync.append(folder)
            }
        }
        return plan
    }
}
