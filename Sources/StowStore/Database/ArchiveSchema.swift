import Foundation
import GRDB

/// The archive's database schema and its migrations (owned by Track B; see
/// `docs/schema.md` for the reason behind every column).
///
/// Migrations are registered in order with GRDB's `DatabaseMigrator`, which
/// records each one in `grdb_migrations` and runs only those not yet applied.
/// A migration that has shipped is never edited: changes go in a new one.
public enum ArchiveSchema {
    /// Every migration identifier, oldest first. Tests use this to step through versions.
    public static let migrationIdentifiers = ["v1"]

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        return migrator
    }

    /// Applies every outstanding migration.
    public static func migrate(_ writer: some DatabaseWriter) throws {
        try migrator.migrate(writer)
    }

    // MARK: - v1

    static func v1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY NOT NULL,
                provider TEXT NOT NULL CHECK (provider IN ('gmail', 'microsoft')),
                email TEXT NOT NULL,
                display_name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                needs_reauth INTEGER NOT NULL DEFAULT 0,
                mcp_enabled INTEGER NOT NULL DEFAULT 0,
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
                raw_state TEXT NOT NULL DEFAULT 'full' CHECK (raw_state IN ('full', 'skeleton')),
                raw_stored_size INTEGER NOT NULL,
                raw_compacted_at INTEGER,
                parse_status TEXT NOT NULL CHECK (parse_status IN ('ok', 'degraded', 'failed')),
                parse_warnings TEXT,
                parser_version INTEGER NOT NULL,
                imported_at INTEGER NOT NULL,
                UNIQUE (account_id, raw_hash)
            ) STRICT;
            CREATE INDEX messages_account_date ON messages(account_id, internal_date);
            CREATE INDEX messages_date ON messages(internal_date);
            CREATE INDEX messages_gmail_msgid ON messages(account_id, gmail_msgid);
            CREATE INDEX messages_thread ON messages(thread_key);
            CREATE INDEX messages_rfc822_id ON messages(rfc822_message_id);

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
                last_seen_at INTEGER NOT NULL,
                removed_from_server_at INTEGER,
                PRIMARY KEY (message_id, folder_id),
                UNIQUE (folder_id, uid_validity, uid)
            ) STRICT;

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
                highest_uid INTEGER NOT NULL,
                last_sync_at INTEGER,
                last_full_sync_at INTEGER,
                status TEXT NOT NULL DEFAULT 'idle' CHECK (status IN ('idle', 'syncing', 'error')),
                last_error TEXT
            ) STRICT;

            CREATE TABLE rule_overrides (
                id INTEGER PRIMARY KEY,
                account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
                scope TEXT NOT NULL CHECK (scope IN ('address', 'domain')),
                pattern TEXT NOT NULL,
                rule_id TEXT,
                action TEXT NOT NULL CHECK (action IN ('never_flag', 'always_keep', 'always_deprioritise')),
                created_at INTEGER NOT NULL,
                UNIQUE (account_id, scope, pattern, rule_id)
            ) STRICT;

            CREATE VIRTUAL TABLE messages_fts USING fts5(
                subject, from_text, to_text, cc_text, body, attachment_names, attachment_text,
                tokenize = 'porter unicode61 remove_diacritics 2',
                prefix = '2 3'
            );
            """)
    }
}
