import Foundation
import StowCore
import Testing
@testable import StowMCP

/// The assistant is told when Stow could not read all of an email (D-481).
@Suite struct UnreadMarkTests {
    static func detail(incomplete: Bool, attachment: AttachmentInfo) -> MessageDetail {
        MessageDetail(messageID: 7, accountID: AccountID(rawValue: "a"), threadKey: nil, date: Date(timeIntervalSince1970: 0),
                      sentDate: nil, from: nil, to: [], cc: [], subject: nil, sourceState: .present, body: nil,
                      bodyFromHTML: false, bodyLength: 0, bodyTruncated: false, attachments: [attachment], textIncomplete: incomplete)
    }

    @Test func headerAndAttachmentLinesSaySo() {
        let unreadable = AttachmentInfo(index: 1, filename: "scan.pdf", mimeType: "application/pdf", size: 10, disposition: "attachment",
                                        textStatus: "unsupported", textLength: 0, textUnreadable: true)
        let lines = ArchiveTools.headerLines(Self.detail(incomplete: true, attachment: unreadable))
        #expect(lines.contains { $0.hasPrefix("Not read in full: Stow could not read all of this email") })
        #expect(lines.contains { $0.contains("scan.pdf") && $0.contains("text could not be read") })
        #expect(ArchiveTools.noTextReason(unreadable) == "Stow tried to read its text and could not; it tries again after an update.")

        var notRead = unreadable
        notRead.textUnreadable = false
        #expect(!ArchiveTools.headerLines(Self.detail(incomplete: false, attachment: notRead)).contains { $0.hasPrefix("Not read in full") })
        #expect(ArchiveTools.noTextReason(notRead) == "Stow cannot read text from this kind of file.")
    }
}
