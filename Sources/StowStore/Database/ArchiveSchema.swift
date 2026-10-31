import Foundation
import GRDB

/// The archive's database schema and its migrations (owned by Track B; see
/// `docs/schema.md` for the reason behind every column).
///
/// Migrations are registered in order with GRDB's `DatabaseMigrator`, which
/// records each one in `grdb_migrations` and runs only those not yet applied.
/// A migration that has shipped is never edited: changes go in a new one.
/// v1 was revised in Phase 2 before any real mail was imported (D-025); it is
/// frozen from the first real import onwards.
///
/// From v2 on, migrations run on real archives: each one is forward only and
/// keeps the meaning of every existing row. An older build opening a newer
/// archive ignores the migrations it does not know, so new columns need
/// defaults that older code can leave alone.
public enum ArchiveSchema {
    /// Every migration identifier, oldest first. Tests use this to step through versions.
    public static let migrationIdentifiers = ["v1", "v2", "v3", "v4"]

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        migrator.registerMigration("v2", migrate: v2)
        migrator.registerMigration("v3", migrate: v3)
        migrator.registerMigration("v4", migrate: v4)
        return migrator
    }

    /// The newest reader level this build reads (D-536). An archive records the
    /// oldest level that reads it correctly under `min_reader_level` in
    /// `archive_meta`; a missing key means 1. A migration whose change an older
    /// build would misread (a new file flag, a column that must not be ignored)
    /// raises it with `requireReaderLevel`, before anything in the new form is
    /// written, and this constant goes up in the same build.
    public static let readerLevel = 1
    static let readerLevelKey = "min_reader_level"

    /// Refuses an archive that needs a newer reader than this build. Reads only,
    /// so `Archive.open` runs it before the migrator, read-only or not.
    public static func checkReaderLevel(_ db: Database) throws {
        guard try db.tableExists("archive_meta"),
              let value = try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = ?", arguments: [readerLevelKey])
        else { return }
        guard let needed = Int(value) else { throw ArchiveError.newerArchive(needs: nil, knows: readerLevel) }
        if needed > readerLevel { throw ArchiveError.newerArchive(needs: needed, knows: readerLevel) }
    }

    /// Raises the archive's reader level to `level`, never lowering it. For the
    /// migration that introduces a change an older reader would misread.
    static func requireReaderLevel(_ level: Int, _ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO archive_meta (key, value) VALUES (?, ?)
            ON CONFLICT (key) DO UPDATE SET value = CAST(max(CAST(value AS INTEGER), CAST(excluded.value AS INTEGER)) AS TEXT)
            """, arguments: [readerLevelKey, String(level)])
    }

    /// One line for `stowmail doctor`: the level the archive needs and the newest this build reads.
    public static func readerLevelSummary(_ db: Database) throws -> String {
        let value = try db.tableExists("archive_meta")
            ? try String.fetchOne(db, sql: "SELECT value FROM archive_meta WHERE key = ?", arguments: [readerLevelKey]) : nil
        return "Reader level: needs \(value ?? "1"); this build reads up to \(readerLevel)."
    }

    /// Applies every outstanding migration.
    public static func migrate(_ writer: some DatabaseWriter) throws {
        try migrator.migrate(writer)
    }

    /// One line for `stowmail doctor`: the archive's schema version, read from
    /// GRDB's `grdb_migrations` without changing anything, and the newest
    /// version this build knows. A version written by a newer build is shown as
    /// such, not as an error: older builds read what they know.
    public static func versionSummary(_ db: Database) throws -> String {
        let applied = try db.tableExists("grdb_migrations")
            ? try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") : []
        let known = migrationIdentifiers
        let newest = known.last!
        if let newer = applied.filter({ !known.contains($0) }).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).last {
            return "Schema: \(newer), newer than this build, which knows up to \(newest) and reads what it knows."
        }
        guard let current = known.last(where: applied.contains) else {
            return "Schema: none yet (made the first time this build writes to it). This build knows up to \(newest)."
        }
        if current == newest { return "Schema: \(current). This build knows up to \(newest)." }
        return "Schema: \(current) (upgrades the next time this build writes to it). This build knows up to \(newest)."
    }

    // MARK: - v1

    static func v1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE archive_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            ) STRICT;

            CREATE TABLE accounts (
                id TEXT PRIMARY KEY NOT NULL,
                -- No CHECK: new providers (Build 2 proposals B2-01, B2-02) must not need a table rebuild (D-025).
                provider TEXT NOT NULL,
                email TEXT NOT NULL,
                display_name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                needs_reauth INTEGER NOT NULL DEFAULT 0,
                disconnected_at INTEGER,
                mcp_enabled INTEGER NOT NULL DEFAULT 0,
                retention_months INTEGER,
                coverage_date INTEGER,
                coverage_computed_at INTEGER,
                last_sync_at INTEGER,
                last_success_at INTEGER,
                last_error TEXT,
                last_error_at INTEGER,
                UNIQUE (provider, email)
            ) STRICT;

            CREATE TABLE folders (
                id INTEGER PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('folder', 'label')),
                delimiter TEXT,
                special_use TEXT,
                uid_validity INTEGER,
                is_selectable INTEGER NOT NULL DEFAULT 1,
                skipped_reason TEXT,
                UNIQUE (account_id, kind, name)
            ) STRICT;

            CREATE TABLE addresses (
                id INTEGER PRIMARY KEY,
                address TEXT NOT NULL UNIQUE,
                domain TEXT NOT NULL
            ) STRICT;
            CREATE INDEX addresses_domain ON addresses(domain);

            CREATE TABLE messages (
                id INTEGER PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                raw_hash BLOB NOT NULL,
                rfc822_message_id TEXT,
                gmail_msgid INTEGER,
                gmail_thrid INTEGER,
                thread_key TEXT,
                internal_date INTEGER NOT NULL,
                sent_date INTEGER,
                date_raw TEXT,
                subject TEXT,
                from_address_id INTEGER REFERENCES addresses(id),
                size INTEGER NOT NULL,
                has_attachments INTEGER NOT NULL DEFAULT 0,
                raw_state TEXT NOT NULL CHECK (raw_state IN ('full', 'skeleton')),
                raw_stored_size INTEGER NOT NULL,
                raw_inline_attachments INTEGER NOT NULL DEFAULT 0,
                parse_status TEXT NOT NULL CHECK (parse_status IN ('ok', 'degraded', 'failed')),
                parse_warnings TEXT,
                parser_version INTEGER NOT NULL,
                source_state TEXT NOT NULL DEFAULT 'present'
                    CHECK (source_state IN ('present', 'spam', 'trashed', 'gone')),
                source_state_at INTEGER,
                rule_suggestion TEXT CHECK (rule_suggestion IN ('keep', 'deprioritise', 'consider_deleting')),
                rule_score INTEGER,
                rule_signals TEXT,
                imported_at INTEGER NOT NULL,
                UNIQUE (account_id, raw_hash)
            ) STRICT;
            CREATE INDEX messages_account_date ON messages(account_id, internal_date);
            CREATE INDEX messages_date ON messages(internal_date);
            CREATE INDEX messages_gmail_msgid ON messages(account_id, gmail_msgid);
            CREATE INDEX messages_thread ON messages(thread_key);
            CREATE INDEX messages_rfc822_id ON messages(rfc822_message_id);
            CREATE INDEX messages_raw_hash ON messages(raw_hash);
            CREATE INDEX messages_source_state ON messages(account_id, source_state);
            CREATE INDEX messages_rule_suggestion ON messages(account_id, rule_suggestion);
            CREATE INDEX messages_spam ON messages(id) WHERE source_state = 'spam';

            CREATE TABLE message_bodies (
                message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                text_plain TEXT,
                text_from_html TEXT
            ) STRICT;

            CREATE TABLE message_folders (
                message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                uid_validity INTEGER,
                uid INTEGER,
                flags TEXT,
                last_seen_at INTEGER NOT NULL,
                removed_from_server_at INTEGER,
                PRIMARY KEY (message_id, folder_id),
                UNIQUE (folder_id, uid_validity, uid)
            ) STRICT;
            CREATE INDEX message_folders_folder ON message_folders(folder_id, uid_validity, removed_from_server_at);

            CREATE TABLE message_addresses (
                message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                role TEXT NOT NULL CHECK (role IN ('from', 'sender', 'reply_to', 'to', 'cc', 'bcc', 'delivered_to')),
                position INTEGER NOT NULL,
                address_id INTEGER NOT NULL REFERENCES addresses(id),
                display_name TEXT,
                PRIMARY KEY (message_id, role, position)
            ) STRICT;
            CREATE INDEX message_addresses_address ON message_addresses(address_id, role);

            CREATE TABLE attachments (
                id INTEGER PRIMARY KEY,
                content_hash BLOB NOT NULL UNIQUE,
                size INTEGER NOT NULL,
                stored_size INTEGER NOT NULL,
                mime_type TEXT,
                text_status TEXT NOT NULL CHECK (text_status IN
                    ('none', 'extracted', 'ocr_pending', 'ocr_done', 'ocr_failed', 'unsupported')),
                created_at INTEGER NOT NULL
            ) STRICT;
            CREATE INDEX attachments_text_status ON attachments(text_status);

            CREATE TABLE message_attachments (
                message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                part_path TEXT NOT NULL,
                attachment_id INTEGER NOT NULL REFERENCES attachments(id),
                filename TEXT,
                declared_mime_type TEXT,
                disposition TEXT CHECK (disposition IN ('attachment', 'inline')),
                content_id TEXT,
                PRIMARY KEY (message_id, part_path)
            ) STRICT;
            CREATE INDEX message_attachments_attachment ON message_attachments(attachment_id);

            CREATE TABLE attachment_text (
                attachment_id INTEGER PRIMARY KEY REFERENCES attachments(id) ON DELETE CASCADE,
                text TEXT NOT NULL,
                method TEXT NOT NULL CHECK (method IN ('plain', 'pdfkit', 'docx', 'ocr')),
                extractor_version INTEGER NOT NULL,
                extracted_at INTEGER NOT NULL
            ) STRICT;

            CREATE TABLE sync_state (
                folder_id INTEGER PRIMARY KEY REFERENCES folders(id) ON DELETE CASCADE,
                uid_validity INTEGER NOT NULL,
                listed_through_uid INTEGER NOT NULL DEFAULT 0,
                highest_modseq INTEGER,
                server_exists INTEGER,
                last_sync_at INTEGER,
                last_full_sync_at INTEGER,
                first_sync_completed_at INTEGER,
                status TEXT NOT NULL DEFAULT 'idle' CHECK (status IN ('idle', 'syncing', 'error')),
                last_error TEXT
            ) STRICT;

            CREATE TABLE download_queue (
                folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                uid_validity INTEGER NOT NULL,
                uid INTEGER NOT NULL,
                size INTEGER NOT NULL,
                internal_date INTEGER,
                priority INTEGER NOT NULL DEFAULT 0,
                gmail_msgid INTEGER,
                state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'unfetchable')),
                restore INTEGER NOT NULL DEFAULT 0,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_run_id TEXT,
                first_failed_at INTEGER,
                last_failed_at INTEGER,
                flags TEXT,
                recorded_at INTEGER,
                queued_at INTEGER NOT NULL,
                PRIMARY KEY (folder_id, uid_validity, uid)
            ) STRICT;
            CREATE INDEX download_queue_order ON download_queue(state, priority, folder_id, uid);

            CREATE TABLE byte_budget (
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                at INTEGER NOT NULL,
                bytes INTEGER NOT NULL
            ) STRICT;
            CREATE INDEX byte_budget_account ON byte_budget(account_id, at);

            CREATE TABLE sync_events (
                id INTEGER PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
                kind TEXT NOT NULL,
                old_value TEXT,
                new_value TEXT,
                at INTEGER NOT NULL
            ) STRICT;
            CREATE INDEX sync_events_account ON sync_events(account_id, at);

            CREATE TABLE tombstones (
                id INTEGER PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                raw_hash BLOB NOT NULL,
                gmail_msgid INTEGER,
                rfc822_message_id TEXT,
                internal_date INTEGER NOT NULL,
                size INTEGER NOT NULL,
                sender TEXT,
                reason TEXT NOT NULL,
                removed_at INTEGER NOT NULL,
                restore_requested_at INTEGER,
                UNIQUE (account_id, raw_hash)
            ) STRICT;
            CREATE INDEX tombstones_gmail_msgid ON tombstones(account_id, gmail_msgid);

            CREATE TABLE tombstone_copies (
                tombstone_id INTEGER NOT NULL REFERENCES tombstones(id) ON DELETE CASCADE,
                folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                uid_validity INTEGER NOT NULL,
                uid INTEGER NOT NULL,
                PRIMARY KEY (tombstone_id, folder_id, uid_validity, uid)
            ) STRICT;
            CREATE INDEX tombstone_copies_location ON tombstone_copies(folder_id, uid_validity, uid);

            CREATE TABLE rule_overrides (
                id INTEGER PRIMARY KEY,
                account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
                match TEXT NOT NULL,
                suggestion TEXT NOT NULL CHECK (suggestion IN ('keep', 'deprioritise', 'consider_deleting')),
                created_at INTEGER NOT NULL
            ) STRICT;
            CREATE UNIQUE INDEX rule_overrides_match ON rule_overrides(coalesce(account_id, ''), match);
            """)

        // The full-text index stores no copy of the text it indexes (D-030): its
        // content comes from this view over the tables above, so FTS5 reads it
        // back from there for snippets. Every change to that text must remove the
        // message's index entry first and add it again afterwards (SearchIndexWriter).
        try db.execute(sql: """
            CREATE VIEW messages_fts_content AS
            SELECT m.id AS id,
                m.subject AS subject,
                (SELECT group_concat(\(addressText), ', ' ORDER BY ma.role, ma.position)
                    FROM message_addresses ma JOIN addresses a ON a.id = ma.address_id
                    WHERE ma.message_id = m.id AND ma.role IN ('from', 'sender', 'reply_to')) AS from_text,
                (SELECT group_concat(\(addressText), ', ' ORDER BY ma.role, ma.position)
                    FROM message_addresses ma JOIN addresses a ON a.id = ma.address_id
                    WHERE ma.message_id = m.id AND ma.role = 'to') AS to_text,
                (SELECT group_concat(\(addressText), ', ' ORDER BY ma.role, ma.position)
                    FROM message_addresses ma JOIN addresses a ON a.id = ma.address_id
                    WHERE ma.message_id = m.id AND ma.role IN ('cc', 'bcc')) AS cc_text,
                (SELECT coalesce(b.text_plain, b.text_from_html) FROM message_bodies b WHERE b.message_id = m.id) AS body,
                (SELECT group_concat(x.filename, char(10) ORDER BY x.part_path)
                    FROM message_attachments x WHERE x.message_id = m.id AND x.filename IS NOT NULL) AS attachment_names,
                (SELECT group_concat(t.text, char(10, 10) ORDER BY t.first_part)
                    FROM (SELECT at.text AS text, min(x.part_path) AS first_part
                          FROM message_attachments x JOIN attachment_text at ON at.attachment_id = x.attachment_id
                          WHERE x.message_id = m.id GROUP BY x.attachment_id) t) AS attachment_text
            FROM messages m;

            CREATE VIRTUAL TABLE messages_fts USING fts5(
                subject, from_text, to_text, cc_text, body, attachment_names, attachment_text,
                content = 'messages_fts_content',
                content_rowid = 'id',
                tokenize = 'porter unicode61 remove_diacritics 2',
                prefix = '2 3'
            );
            """)
    }

    // MARK: - v2

    /// Text Stow could not read, and attempts recorded before each try (D-481, D-501).
    ///
    /// Columns only, each with a constant default, so no table is rebuilt and every
    /// existing row means what it did: its text is complete and nothing has been
    /// attempted. The attempt counts start again only when a row is marked (or its
    /// text is read), never when a retry round starts, so a build that crashes on
    /// the same item every time still reaches the limit.
    static func v2(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE messages ADD COLUMN text_state TEXT NOT NULL DEFAULT 'complete'
                CHECK (text_state IN ('complete', 'incomplete'));
            -- MIMEParser.version when marked: set exactly when the text is incomplete.
            ALTER TABLE messages ADD COLUMN text_marked_version INTEGER
                CHECK ((text_marked_version IS NULL) = (text_state = 'complete'));
            -- Re-parse attempts on a stored message since it was last marked.
            ALTER TABLE messages ADD COLUMN text_attempts INTEGER NOT NULL DEFAULT 0;
            CREATE INDEX messages_text_incomplete ON messages(text_marked_version) WHERE text_state = 'incomplete';

            -- Import attempts before a downloaded message becomes a row. `attempts` still counts fetch failures.
            ALTER TABLE download_queue ADD COLUMN import_attempts INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE download_queue ADD COLUMN last_import_attempt_at INTEGER;

            ALTER TABLE attachments ADD COLUMN text_attempts INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE attachments ADD COLUMN text_last_attempt_at INTEGER;
            -- TextExtractor.version or OCRQueue.version when reading failed; NULL for a type Stow does not read.
            ALTER TABLE attachments ADD COLUMN text_failed_version INTEGER;
            CREATE INDEX attachments_text_failed ON attachments(text_status, text_failed_version) WHERE text_failed_version IS NOT NULL;
            """)
    }

    // MARK: - v3

    /// The provider's own DMARC result for the From domain, per message (D-521, D-522).
    ///
    /// One nullable column with no default, so no row is rewritten and every
    /// existing message reads NULL: not yet read. An older build that does not know
    /// the column inserts NULL too, which means the same. The partial index holds
    /// only those rows, so the backfill and its "anything left?" check read nothing
    /// once every message has a result.
    static func v3(_ db: Database) throws {
        try db.execute(sql: """
            -- ProviderAuthentication.dmarc's answer; NULL until the message's headers are read.
            ALTER TABLE messages ADD COLUMN sender_dmarc TEXT
                CHECK (sender_dmarc IN ('pass', 'fail', 'none'));
            CREATE INDEX messages_dmarc_pending ON messages(id) WHERE sender_dmarc IS NULL;
            """)
    }

    // MARK: - v4

    /// The DMARC rule loosened (D-523: a pass for a parent of the From domain
    /// counts), so every stored result is cleared and the backfill reads it again
    /// by the new rule (D-522). Data only: no column or index changes. A migration
    /// runs once per archive, so results written afterwards are kept. An older
    /// build skips it and keeps reading the column.
    static func v4(_ db: Database) throws {
        try db.execute(sql: "UPDATE messages SET sender_dmarc = NULL")
    }

    /// "Name address", or just the address when there is no display name.
    private static let addressText = "CASE WHEN ma.display_name IS NULL THEN a.address ELSE ma.display_name || ' ' || a.address END"
}
