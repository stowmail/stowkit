import Foundation
import GRDB
import StowCore
import StowStore

/// Full-text search over the archive (brief step 6, D-206).
///
/// Ranking is FTS5's bm25 with per-column weights: subject 10, from 6,
/// body 3, to 2, attachment names 2, cc 1, attachment text 1. Searches run in
/// two steps so the expensive parts (snippets, matched fields) are computed
/// for the returned page only, not for every match.
public final class MessageSearcher: MessageSearching, Sendable {
    /// Column order of `messages_fts`, with each column's weight and field.
    static let columns: [(name: String, weight: Double, field: SearchField)] = [
        ("subject", 10, .subject), ("from_text", 6, .from), ("to_text", 2, .to), ("cc_text", 1, .cc),
        ("body", 3, .body), ("attachment_names", 2, .attachmentName), ("attachment_text", 1, .attachmentText),
    ]

    static var bm25: String {
        "bm25(messages_fts, \(columns.map { String($0.weight) }.joined(separator: ", ")))"
    }

    let database: any DatabaseReader

    public init(database: any DatabaseReader) {
        self.database = database
    }

    public convenience init(archive: Archive) {
        self.init(database: archive.database)
    }

    public func search(_ query: SearchQuery) async throws -> [SearchHit] {
        try await database.read { db in try self.search(db, query) }
    }

    public func count(_ query: SearchQuery) async throws -> Int {
        try await database.read { db in try self.count(db, query) }
    }

    public func folders(accounts: [AccountID]) async throws -> [ArchiveFolder] {
        try await database.read { db in try self.folders(db, accounts: accounts) }
    }

    public func thread(of message: StoredMessageID) async throws -> MessageThread? {
        try await database.read { db in try self.thread(db, of: message) }
    }

    public func senderSuggestions(prefix: String, accounts: [AccountID], limit: Int) async throws -> [SenderSuggestion] {
        try await database.read { db in try self.senderSuggestions(db, prefix: prefix, accounts: accounts, limit: limit) }
    }

    /// The MATCH expression for a query, or nil if it has no text conditions.
    static func matchExpression(_ query: SearchQuery) -> String? {
        var parts: [String] = []
        if let text = FTSExpression.build(query.text) { parts.append("(\(text))") }
        if let from = query.from, let expression = FTSExpression.build(from, columns: ["from_text"]) { parts.append(expression) }
        if let to = query.to, let expression = FTSExpression.build(to, columns: ["to_text", "cc_text"]) { parts.append(expression) }
        if let subject = query.subject, let expression = FTSExpression.build(subject, columns: ["subject"]) { parts.append(expression) }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    /// The conditions on `messages m` a query adds besides its MATCH expression.
    struct Conditions {
        var filters: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        /// True when nothing can match, such as an `in:` name no folder has.
        var matchesNothing = false
        /// The place filter's folders. Its condition is always the last filter.
        var placeIDs: [FolderID]?

        var whereClause: String { filters.isEmpty ? "" : "WHERE \(filters.joined(separator: " AND "))" }
    }

    func conditions(_ db: Database, _ query: SearchQuery) throws -> Conditions {
        var result = Conditions()
        if let has = query.hasAttachment {
            result.filters.append("m.has_attachments = ?")
            result.arguments.append(has)
        }
        if !query.accounts.isEmpty {
            result.filters.append("m.account_id IN (\(Self.placeholders(query.accounts.count)))")
            result.arguments.append(contentsOf: query.accounts.map(\.rawValue))
        }
        if let since = query.since {
            result.filters.append("m.internal_date >= ?")
            result.arguments.append(Int(since.timeIntervalSince1970))
        }
        if let before = query.before {
            result.filters.append("m.internal_date < ?")
            result.arguments.append(Int(before.timeIntervalSince1970))
        }
        switch query.spam {
        case .hide:
            // Most archives hold no spam; then the filter is skipped, keeping the fastest query shape.
            if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE source_state = 'spam')") == true {
                result.filters.append("m.source_state != 'spam'")
            }
        case .only: result.filters.append("m.source_state = 'spam'")
        case .include: break
        }
        if let place = query.place {
            let ids = try placeIDs(db, place, accounts: query.accounts)
            if ids.isEmpty {
                result.matchesNothing = true
            } else {
                // EXISTS, not `m.id IN (subquery)`: the IN form is catastrophically slow beside FTS (D-206).
                result.filters.append("""
                    EXISTS (SELECT 1 FROM message_folders mf WHERE mf.message_id = m.id \
                    AND mf.folder_id IN (\(Self.placeholders(ids.count))) AND mf.removed_from_server_at IS NULL)
                    """)
                result.arguments.append(contentsOf: ids)
                result.placeIDs = ids
            }
        }
        return result
    }

    /// The folders and labels a place filter means, within the given accounts (all if empty).
    func placeIDs(_ db: Database, _ place: SearchQuery.PlaceFilter, accounts: [AccountID]) throws -> [FolderID] {
        switch place {
        case .folder(let id):
            return [id]
        case .named(let name):
            let wanted = name.trimmingCharacters(in: .whitespaces)
            guard !wanted.isEmpty else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, account_id, name, special_use FROM folders
                \(accounts.isEmpty ? "" : "WHERE account_id IN (\(Self.placeholders(accounts.count)))")
                """, arguments: StatementArguments(accounts.map(\.rawValue)))
            return rows.filter { row in
                let folder: String = row["name"]
                let specialUse: String? = row["special_use"]
                return Self.sameName(folder, wanted) || Self.sameName(folder, "\\" + wanted)
                    || specialUse.map { Self.sameName($0, "\\" + wanted) } == true
            }.map { $0["id"] }
        }
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive]) == .orderedSame
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    func count(_ db: Database, _ query: SearchQuery) throws -> Int {
        let conditions = try conditions(db, query)
        if conditions.matchesNothing { return 0 }
        if let match = Self.matchExpression(query) {
            if conditions.filters.isEmpty {
                return try Int.fetchOne(db, sql: "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH ?",
                                        arguments: [match]) ?? 0
            }
            return try Int.fetchOne(db, sql: """
                SELECT count(*) FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
                WHERE messages_fts MATCH ? AND \(conditions.filters.joined(separator: " AND "))
                """, arguments: StatementArguments([match] + conditions.arguments)) ?? 0
        }
        if let place = conditions.placeIDs {
            // Counting every match: start from the folder's rows rather than test every message (D-079).
            // A plain `IN` is safe here; only `rowid IN` beside FTS is slow (D-206).
            let rest = conditions.filters.dropLast()
            return try Int.fetchOne(db, sql: """
                SELECT count(*) FROM messages m WHERE m.id IN (SELECT mf.message_id FROM message_folders mf
                    WHERE mf.folder_id IN (\(Self.placeholders(place.count))) AND mf.removed_from_server_at IS NULL)
                \(rest.map { "AND \($0)" }.joined(separator: " "))
                """, arguments: StatementArguments(place + conditions.arguments.dropLast(place.count))) ?? 0
        }
        return try Int.fetchOne(db, sql: "SELECT count(*) FROM messages m \(conditions.whereClause)",
                                arguments: StatementArguments(conditions.arguments)) ?? 0
    }

    func search(_ db: Database, _ query: SearchQuery) throws -> [SearchHit] {
        let conditions = try conditions(db, query)
        if conditions.matchesNothing { return [] }
        let filters = conditions.filters
        let arguments = conditions.arguments
        let limit = max(0, min(query.limit, 1000))
        let offset = max(0, query.offset)

        // Step 1: the page of matching message IDs, best first.
        let ranked: [(id: Int64, rank: Double)]
        let match = Self.matchExpression(query)
        if let match {
            // Measured at 100,000 messages (D-206): bm25() over the FTS table alone is fastest
            // without filters; with filters, a plain join beats both a materialised CTE and
            // `rowid IN (subquery)` (which is catastrophically slow).
            let rows: [Row]
            if filters.isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT rowid AS id, \(Self.bm25) AS score FROM messages_fts WHERE messages_fts MATCH ?
                    ORDER BY score LIMIT ? OFFSET ?
                    """, arguments: [match, limit, offset])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT m.id, \(Self.bm25) AS score
                    FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
                    WHERE messages_fts MATCH ? AND \(filters.joined(separator: " AND "))
                    ORDER BY score LIMIT ? OFFSET ?
                    """, arguments: StatementArguments([match] + arguments + [limit, offset]))
            }
            ranked = rows.map { ($0["id"], $0["score"]) }
        } else {
            // No text: newest first, with or without filters (D-052, D-079).
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id FROM messages m \(conditions.whereClause)
                ORDER BY m.internal_date DESC, m.id DESC LIMIT ? OFFSET ?
                """, arguments: StatementArguments(arguments + [limit, offset]))
            ranked = rows.map { ($0["id"], 0) }
        }
        guard !ranked.isEmpty else { return [] }

        // Step 2: details, snippets and matched fields for this page only.
        let ids = ranked.map(\.id)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let details = try Row.fetchAll(db, sql: """
            SELECT m.id, m.account_id, m.thread_key, m.internal_date, m.subject, m.has_attachments, m.source_state,
                   a.address AS from_address, ma.display_name AS from_name,
                   EXISTS (SELECT 1 FROM message_attachments x JOIN attachments t ON t.id = x.attachment_id
                           WHERE x.message_id = m.id AND t.text_status = 'ocr_pending') AS ocr_pending
            FROM messages m
            LEFT JOIN message_addresses ma ON ma.message_id = m.id AND ma.role = 'from' AND ma.position = 0
            LEFT JOIN addresses a ON a.id = ma.address_id
            WHERE m.id IN (\(placeholders))
            """, arguments: StatementArguments(ids))
        var byID: [Int64: Row] = [:]
        for row in details { byID[row["id"]] = row }

        var snippets: [Int64: (String, Set<SearchField>)] = [:]
        if let match {
            let highlights = Self.columns.indices.map { "highlight(messages_fts, \($0), char(1), char(2)) AS h\($0)" }
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, snippet(messages_fts, -1, '[', ']', '…', 16) AS snippet, \(highlights.joined(separator: ", "))
                FROM messages_fts WHERE messages_fts MATCH ? AND rowid IN (\(placeholders))
                """, arguments: StatementArguments([match] + ids))
            for row in rows {
                var fields = Set<SearchField>()
                for (index, column) in Self.columns.enumerated() {
                    if let text: String = row["h\(index)"], text.contains("\u{1}") { fields.insert(column.field) }
                }
                snippets[row["rowid"]] = (row["snippet"] ?? "", fields)
            }
        }

        return ranked.compactMap { item in
            guard let row = byID[item.id] else { return nil }
            let address: String? = row["from_address"]
            let subject: String? = row["subject"]
            let (snippet, fields) = snippets[item.id] ?? (subject ?? "", [])
            return SearchHit(
                messageID: item.id,
                accountID: AccountID(rawValue: row["account_id"]),
                threadKey: row["thread_key"],
                date: Date(timeIntervalSince1970: TimeInterval(row["internal_date"] as Int64)),
                from: address.map { EmailAddress(name: row["from_name"], address: $0) },
                subject: subject,
                snippet: snippet.replacingOccurrences(of: "\n", with: " "),
                rank: item.rank,
                matchedFields: fields,
                hasAttachments: row["has_attachments"],
                ocrPending: row["ocr_pending"],
                sourceState: SourceState(rawValue: row["source_state"]) ?? .present
            )
        }
    }

    // MARK: Sender suggestions (D-057, R5)

    /// Most suggestions one call returns.
    public static let maximumSenderSuggestions = 50

    /// Distinct From addresses (the first From of each message) whose address,
    /// display name, or a word of the display name starts with `prefix`,
    /// case-insensitively, by how many messages each sent. No extra index: the
    /// From rows are scanned once (timing in D-403).
    func senderSuggestions(_ db: Database, prefix: String, accounts: [AccountID], limit: Int) throws -> [SenderSuggestion] {
        let wanted = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let limit = min(max(0, limit), Self.maximumSenderSuggestions)
        guard !wanted.isEmpty, limit > 0 else { return [] }
        let pattern = Self.likeLiteral(wanted) + "%"
        var filters = ["""
            (a.address LIKE ? ESCAPE '\\' OR ma.display_name LIKE ? ESCAPE '\\' OR ma.display_name LIKE ? ESCAPE '\\')
            """]
        var arguments: [any DatabaseValueConvertible] = [pattern, pattern, "% " + pattern]
        if !accounts.isEmpty {
            filters.append("m.account_id IN (\(Self.placeholders(accounts.count)))")
            arguments.append(contentsOf: accounts.map(\.rawValue))
        }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE source_state = 'spam')") == true {
            filters.append("m.source_state != 'spam'")
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id, a.address, count(*) AS n
            FROM message_addresses ma JOIN addresses a ON a.id = ma.address_id JOIN messages m ON m.id = ma.message_id
            WHERE ma.role = 'from' AND ma.position = 0 AND \(filters.joined(separator: " AND "))
            GROUP BY a.id ORDER BY n DESC, a.address LIMIT ?
            """, arguments: StatementArguments(arguments + [limit]))
        return try rows.map { row in
            // The display name this address most often used, for the token's label.
            let name = try String.fetchOne(db, sql: """
                SELECT display_name FROM message_addresses WHERE address_id = ? AND role = 'from' AND display_name IS NOT NULL
                GROUP BY display_name ORDER BY count(*) DESC, display_name LIMIT 1
                """, arguments: [row["id"] as Int64])
            return SenderSuggestion(sender: EmailAddress(name: name, address: row["address"]), messageCount: row["n"])
        }
    }

    /// `text` matched literally inside a LIKE pattern with `ESCAPE '\'`.
    static func likeLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Folders and threads (D-079)

    /// Folders sync downloads (every Microsoft folder it keeps, Gmail's All Mail)
    /// and Gmail labels: the places a search can be limited to. Folders sync
    /// leaves out (Gmail's label folders, Junk, `\Noselect`, gone) hold no
    /// current copies, so they are not offered.
    func folders(_ db: Database, accounts: [AccountID]) throws -> [ArchiveFolder] {
        var filters = ["f.is_selectable = 1", "(f.kind = 'label' OR f.skipped_reason IS NULL)"]
        if !accounts.isEmpty { filters.append("f.account_id IN (\(Self.placeholders(accounts.count)))") }
        return try Row.fetchAll(db, sql: """
            SELECT f.id, f.account_id, f.name, f.kind, f.special_use, f.delimiter FROM folders f
            WHERE \(filters.joined(separator: " AND "))
            ORDER BY f.account_id, f.kind, f.name COLLATE NOCASE
            """, arguments: StatementArguments(accounts.map(\.rawValue))).map { row in
            ArchiveFolder(id: row["id"], accountID: AccountID(rawValue: row["account_id"]), name: row["name"],
                          kind: ArchiveFolder.Kind(rawValue: row["kind"]) ?? .folder,
                          specialUse: row["special_use"], delimiter: row["delimiter"])
        }
    }

    /// The thread of a message within its own account, oldest first by arrival
    /// (`internal_date`, then ID). Spam members are left out unless the message
    /// asked about is spam itself. Longer than `MessageThread.maximumMessages`:
    /// a window centred on the message asked about.
    func thread(_ db: Database, of message: StoredMessageID) throws -> MessageThread? {
        guard let row = try Row.fetchOne(db, sql: "SELECT account_id, thread_key, source_state FROM messages WHERE id = ?",
                                         arguments: [message]) else { return nil }
        let account: String = row["account_id"]
        let threadKey: String? = row["thread_key"]
        // `+m.account_id` keeps SQLite on the thread_key index; otherwise it walks
        // (account_id, internal_date) for the ORDER BY, every message of the account (D-079).
        var members = [message]
        if let threadKey {
            let spamRule = (row["source_state"] as String) == SourceState.spam.rawValue ? "" : "AND (m.source_state != 'spam' OR m.id = ?)"
            members = try Int64.fetchAll(db, sql: """
                SELECT m.id FROM messages m WHERE m.thread_key = ? AND +m.account_id = ? \(spamRule)
                ORDER BY m.internal_date, m.id
                """, arguments: StatementArguments([threadKey, account] + (spamRule.isEmpty ? [] : [message])))
        }
        guard let position = members.firstIndex(of: message) else { return nil }
        let size = MessageThread.maximumMessages
        let start = max(0, min(position - size / 2, members.count - size))
        let window = Array(members[start..<min(members.count, start + size)])

        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id, m.internal_date, m.subject, m.has_attachments, m.source_state,
                   a.address AS from_address, ma.display_name AS from_name
            FROM messages m
            LEFT JOIN message_addresses ma ON ma.message_id = m.id AND ma.role = 'from' AND ma.position = 0
            LEFT JOIN addresses a ON a.id = ma.address_id
            WHERE m.id IN (\(Self.placeholders(window.count)))
            """, arguments: StatementArguments(window))
        var byID: [Int64: Row] = [:]
        for row in rows { byID[row["id"]] = row }
        let summaries = window.compactMap { id -> ThreadMessage? in
            guard let row = byID[id] else { return nil }
            let address: String? = row["from_address"]
            return ThreadMessage(
                messageID: id,
                date: Date(timeIntervalSince1970: TimeInterval(row["internal_date"] as Int64)),
                from: address.map { EmailAddress(name: row["from_name"], address: $0) },
                subject: row["subject"],
                sourceState: SourceState(rawValue: row["source_state"]) ?? .present,
                hasAttachments: row["has_attachments"])
        }
        return MessageThread(accountID: AccountID(rawValue: account), threadKey: threadKey, messages: summaries,
                             selectedIndex: position - start, totalCount: members.count)
    }
}
