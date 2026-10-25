import Foundation
import GRDB
import StowCore

/// Senders whose mail the user protects: never suggested for removal (UI-10,
/// D-407). Kept in the encrypted archive because they name people (D-041),
/// as one JSON list under the `protected_senders` key of `archive_meta`, so no
/// schema change was needed (D-025). They apply to every account.
public struct ProtectedSenders: Sendable {
    static let key = "protected_senders"

    public let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    /// Normalised addresses (`ana@example.org`) and bare domains (`example.org`), sorted.
    public func list() throws -> [String] {
        try archive.database.read { db in try Self.list(db) }
    }

    static func list(_ db: Database) throws -> [String] {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = ?", arguments: [key]),
              let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8))
        else { return [] }
        return list
    }

    /// Protects an address or domain. Returns false if it was already protected.
    @discardableResult
    public func add(_ match: String) throws -> Bool {
        let normalised = RuleOverrides.normalise(match)
        guard !normalised.isEmpty else { return false }
        return try update { list in
            guard !list.contains(normalised) else { return false }
            list.append(normalised)
            return true
        }
    }

    /// Stops protecting an address or domain. Returns whether it was protected.
    @discardableResult
    public func remove(_ match: String) throws -> Bool {
        let normalised = RuleOverrides.normalise(match)
        return try update { list in
            guard let index = list.firstIndex(of: normalised) else { return false }
            list.remove(at: index)
            return true
        }
    }

    private func update(_ change: (inout [String]) -> Bool) throws -> Bool {
        try archive.database.write { db in
            var list = try Self.list(db)
            guard change(&list) else { return false }
            let text = String(decoding: try JSONEncoder().encode(list.sorted()), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO archive_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value
                """, arguments: [Self.key, text])
            return true
        }
    }
}
