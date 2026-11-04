import Foundation
@testable import StowStore

/// Invented mail shaped like a Google Takeout export (D-018: generated, never
/// committed, never real). Addresses are in the reserved example domains.
///
/// Takeout writes a `From <id>@xxx <date>` line, then `X-GM-THRID` and
/// `X-Gmail-Labels` ahead of the message's own headers, CR LF line endings,
/// and a blank line after each message.
enum SyntheticTakeout {
    struct Message {
        var threadID: UInt64
        var labels: [String]
        var date: Date
        /// The message as Gmail holds it, without the two Takeout headers.
        var body: Data

        /// What the mbox holds for this message once the framing is undone.
        var stored: Data {
            var bytes = Data("X-GM-THRID: \(threadID)\r\nX-Gmail-Labels: \(labels.joined(separator: ","))\r\n".utf8)
            bytes.append(body)
            return bytes
        }
    }

    /// `count` messages from `seed`: plain and multipart with a base64
    /// attachment, a reply in the same thread, a body line starting `From `
    /// and one starting `>From `, so quoting is exercised.
    static func messages(count: Int, seed: UInt64 = 1) -> [Message] {
        var random = Seeded(state: seed)
        let labelSets = [["Inbox", "Opened"], ["Sent"], ["Inbox", "Starred", "Important"], ["Archived", "Projects/Alpha"],
                         ["Spam"], ["Trash"], ["Inbox", "Category Updates", "Unread"]]
        return (0..<count).map { index in
            let thread = 1_700_000_000_000_000_000 + UInt64(index / 2)
            let date = Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 3_600)
            let id = "<takeout-\(seed)-\(index)@example.org>"
            var lines = [
                "Date: \(rfc5322(date))",
                "From: Robin Example <robin\(index % 5)@example.org>",
                "To: Sam Taylor <sam@example.com>",
                "Subject: Synthetic message \(index)",
                "Message-ID: \(id)",
            ]
            if index % 2 == 1 { lines.append("In-Reply-To: <takeout-\(seed)-\(index - 1)@example.org>") }
            lines.append("MIME-Version: 1.0")
            let text = [
                "Hello Sam,",
                "",
                "From the start this line begins with From and a space.",
                ">From here on it is quoted once already.",
                "Line \(random.next() % 1000) of an invented message.",
                "",
            ].joined(separator: "\r\n")
            if index % 3 == 0 {
                let attachment = Data((0..<(600 + Int(random.next() % 2000))).map { _ in UInt8(truncatingIfNeeded: random.next()) })
                lines += [
                    "Content-Type: multipart/mixed; boundary=\"b\(index)\"",
                    "",
                    "--b\(index)",
                    "Content-Type: text/plain; charset=utf-8",
                    "",
                    text,
                    "--b\(index)",
                    "Content-Type: application/octet-stream",
                    "Content-Disposition: attachment; filename=\"data\(index).bin\"",
                    "Content-Transfer-Encoding: base64",
                    "",
                    attachment.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]),
                    "--b\(index)--",
                    "",
                ]
            } else {
                lines += ["Content-Type: text/plain; charset=utf-8", "", text]
            }
            return Message(threadID: thread, labels: labelSets[index % labelSets.count], date: date,
                           body: Data(lines.joined(separator: "\r\n").utf8))
        }
    }

    /// The mbox file: each message mboxrd-quoted after a Takeout `From ` line, then a blank line.
    static func mbox(_ messages: [Message]) -> Data {
        var file = Data()
        for (index, message) in messages.enumerated() { file.append(entry(message, index: index)) }
        return file
    }

    static func entry(_ message: Message, index: Int) -> Data {
        var entry = Data("From \(1_780_000_000_000_000_000 + UInt64(index))@xxx \(fromLineDate(message.date))\r\n".utf8)
        entry.append(MboxExport.quote(message.stored))
        entry.append(Data("\r\n".utf8))
        return entry
    }

    /// As Takeout writes it: `Mon Sep 18 10:12:13 +0000 2023`.
    static func fromLineDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.string(from: date)
    }

    static func rfc5322(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// SplitMix64, so every run makes the same file.
    struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
