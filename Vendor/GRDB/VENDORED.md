# Vendored GRDB.swift

- Upstream: https://github.com/groue/GRDB.swift, tag v7.11.1 (MIT, see LICENSE)
- SQLCipher: local package `../SQLCipher` (Zetetic xcframework, see scripts/fetch-sqlcipher.sh)
- Contents: `GRDB/` and `Sources/GRDBSQLCipher/` unchanged from upstream; `Package.swift` generated.
- Why vendored rather than forked: see D-011 in the Stow decision log.
- Regenerate with `scripts/vendor-grdb.sh`. Never edit files here by hand.
