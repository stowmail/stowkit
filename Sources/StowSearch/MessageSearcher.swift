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

    /// The MATCH expression for a query, or nil if it has no text conditions.
    static func matchExpression(_ query: SearchQuery) -> String? {
        var parts: [String] = []
        if let text = FTSExpression.build(query.text) { parts.append("(\(text))") }
        if let from = query.from, let expression = FTSExpression.build(from, columns: ["from_text"]) { parts.append(expression) }
        if let to = query.to, let expression = FTSExpression.build(to, columns: ["to_text", "cc_text"]) { parts.append(expression) }
        if let subject = query.subject, let expression = FTSExpression.build(subject, columns: ["subject"]) { parts.append(expression) }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    func search(_ db: Database, _ query: SearchQuery) throws -> [SearchHit] {
        var filters: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if let has = query.hasAttachment {
            filters.append("m.has_attachments = ?")
            arguments.append(has)
        }
        if !query.accounts.isEmpty {
            filters.append("m.account_id IN (\(Array(repeating: "?", count: query.accounts.count).joined(separator: ",")))")
            arguments.append(contentsOf: query.accounts.map(\.rawValue))
        }
        if let since = query.since {
            filters.append("m.internal_date >= ?")
            arguments.append(Int(since.timeIntervalSince1970))
        }
        if let before = query.before {
            filters.append("m.internal_date < ?")
            arguments.append(Int(before.timeIntervalSince1970))
        }
        switch query.spam {
        case .hide:
            // Most archives hold no spam; then the filter is skipped, keeping the fastest query shape.
            if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE source_state = 'spam')") == true {
                filters.append("m.source_state != 'spam'")
            }
        case .only: filters.append("m.source_state = 'spam'")
        case .include: break
        }
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
        } else if query.hasAttachment != nil || !query.accounts.isEmpty || query.since != nil || query.before != nil
                    || query.spam == .only {
            // Filters only: newest first.
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id FROM messages m WHERE \(filters.joined(separator: " AND "))
                ORDER BY m.internal_date DESC LIMIT ? OFFSET ?
                """, arguments: StatementArguments(arguments + [limit, offset]))
            ranked = rows.map { ($0["id"], 0) }
        } else {
            return []
        }
        guard !ranked.isEmpty else { return [] }

        // Step 2: details, snippets and matched fields for this page only.
        let ids = ranked.map(\.id)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let details = try Row.fetchAll(db, sql: """
            SELECT m.id, m.account_id, m.thread_key, m.internal_date, m.subject, m.has_attachments,
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
                ocrPending: row["ocr_pending"]
            )
        }
    }
}
