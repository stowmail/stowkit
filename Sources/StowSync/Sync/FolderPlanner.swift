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
    ///   people often treat it as storage.
    public static func plan(provider: Provider, folders: [IMAPFolder], capabilities: Set<String>) throws -> FolderPlan {
        switch provider {
        case .gmail: try planGmail(folders: folders, capabilities: capabilities)
        case .microsoft: planMicrosoft(folders: folders)
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

    static func planMicrosoft(folders: [IMAPFolder]) -> FolderPlan {
        var plan = FolderPlan(toSync: [], skipped: [])
        for folder in folders {
            if !folder.isSelectable {
                plan.skipped.append(.init(folder: folder, reason: "cannot be opened (\\Noselect)"))
            } else if folder.has("\\Junk") {
                plan.skipped.append(.init(folder: folder, reason: "Junk: not archived (D-104)"))
            } else {
                plan.toSync.append(folder)
            }
        }
        return plan
    }
}
