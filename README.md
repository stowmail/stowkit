# StowKit

The engine behind Stow: a local, encrypted, searchable email archive for macOS.
IMAP sync with OAuth, encrypted SQLite storage, full-text search, bulk-mail
rules and a local MCP server. No UI code lives here.

Status: Phase 2 (integration: sync into the encrypted archive, scheduler, background sync). Private until the Phase 4 security review.

## Requirements

- macOS 14 or later, Xcode with Swift 6.1 or later
- `brew install gitleaks`

## Getting started

```sh
scripts/install-hooks.sh     # gitleaks pre-commit hook (once per clone)
scripts/check.sh             # fetches SQLCipher, makes fixtures, builds, tests, scans for secrets
swift run stowmail doctor    # checks SQLCipher, Keychain backend, configuration and the archive
swift run stowmail init      # creates the encrypted archive and shows its recovery key once
```

App configuration (OAuth client IDs) goes in `.env`, copied from `.env.example`.
It is git-ignored and never committed. User tokens and encryption keys live in
the macOS Keychain only.

## Modules

| Module | Job |
|---|---|
| `StowCore` | Shared types and protocols: accounts and the account directory, raw messages, sink and source, sync state, headers, search shapes, log redaction. A file-based raw message store for tests and imports. No package dependencies. |
| `StowSecrets` | Keychain access, OAuth token storage, archive key management, the recovery key and its bundle, app configuration. |
| `StowSync` | IMAP sync and OAuth sign-in. Read-only by construction: commands only through `ReadOnlyCommand` (EXAMINE, `BODY.PEEK[]`). |
| `StowStore` | MIME parsing, encrypted database, skeletons and attachment files, the sync sink and state, accounts, tidy-up, coverage, verify, export, archive location. |
| `StowSearch` | FTS5 search, text extraction and OCR. |
| `StowRules` | Bulk-mail signals and rules, from headers only. |
| `StowMCP` | Local, read-only MCP server. |
| `StowEngine` | Joins sync, storage and rules: the scheduler and background sync, archive setup and recovery, rules over the archive, logs. Used by the CLI and the app. |
| `stowmail` | The command-line tool. |

### Dependency rule

- Every module may depend on `StowCore` and `StowSecrets`.
- `StowSearch` may also depend on `StowStore`.
- Nothing else depends sideways. In particular `StowSync`, `StowStore` and
  `StowRules` never import each other, so they can be built in parallel.
- `stowmail` (the CLI) and `StowEngine` may depend on everything.
- `StowCore` has no package dependencies at all.

If a module needs something from a sibling, the shared part moves into
`StowCore` as a type or protocol.

## Logging policy

swift-log throughout. Never log tokens, keys, passwords, message bodies or
subject lines. Email addresses only at debug level, through `Redact.address`.
Error text from servers or libraries goes through `Redact.scrub` first.

## Dependencies

| Package | Why |
|---|---|
| swift-nio-imap (0.4.x) | IMAP protocol (Apple) |
| swift-nio-transport-services | TLS through Network.framework |
| swift-nio (`NIOCore`) | Channel types used by the IMAP connection; already required by the two above (D-101) |
| swift-argument-parser | CLI |
| swift-log | Logging API |
| GRDB 7.11.1, vendored in `Vendor/GRDB` | SQLite access and migrations, built against SQLCipher |
| SQLCipher 4.19.0, `Vendor/SQLCipher` | Encrypted SQLite (Zetetic's official framework, fetched and verified by `scripts/fetch-sqlcipher.sh`) |

## Scripts

| Script | Does |
|---|---|
| `scripts/check.sh` | Build, test and gitleaks. Must pass before every commit. |
| `scripts/install-hooks.sh` | Points git at `scripts/hooks` (gitleaks pre-commit). |
| `scripts/fetch-sqlcipher.sh` | Downloads SQLCipher, checks its SHA-256 and Zetetic's signature. |
| `scripts/vendor-grdb.sh` | Regenerates `Vendor/GRDB` from an upstream GRDB release. |
| `scripts/make-fixtures` | Generates synthetic `.eml` fixtures into `Tests/Fixtures/eml/`. |

## Licences

GRDB is MIT licensed (`Vendor/GRDB/LICENSE`). SQLCipher Community Edition is
BSD-style (`Vendor/SQLCipher/LICENSE.md`) and requires attribution in
distributed apps. Stow's own licence is decided at the Phase 4 review.
