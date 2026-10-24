#!/usr/bin/env bash
# Fetches Zetetic's official SQLCipher xcframework into Vendor/SQLCipher (D-011).
#
# SwiftPM's own binary download hangs in some sandboxed environments, so the
# framework is fetched here with curl, checked against the SHA-256 published in
# SQLCipher.swift's Package.swift and against Zetetic's code signature, then
# used as a local binary target. The framework itself is git-ignored; this
# script recreates it on any clone or worktree.
#
# Usage: scripts/fetch-sqlcipher.sh   (no-op if already present)

set -euo pipefail

VERSION="4.19.0"
# From https://github.com/sqlcipher/SQLCipher.swift/blob/4.19.0/Package.swift
CHECKSUM="39f02d2f04f0de2ba1facf215550bfc6e6e2c9971d5d8ebb0cdd604874781bd7"
# Zetetic LLC's Apple Developer team. The framework must be signed by it.
TEAM_ID="PD7G6HRMGV"
URL="https://github.com/sqlcipher/SQLCipher.swift/releases/download/$VERSION/SQLCipher.xcframework.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/SQLCipher"
FRAMEWORK="$DEST/SQLCipher.xcframework"
STAMP="$DEST/.fetched-version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION $CHECKSUM" ] && [ -d "$FRAMEWORK" ]; then
    exit 0
fi

CACHE="$HOME/Library/Caches/ee.getstow.dev"
ZIP="$CACHE/SQLCipher-$VERSION.xcframework.zip"
mkdir -p "$CACHE"
if [ ! -f "$ZIP" ] || [ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" != "$CHECKSUM" ]; then
    echo "Downloading SQLCipher $VERSION"
    curl -fsSL "$URL" -o "$ZIP.part"
    mv "$ZIP.part" "$ZIP"
fi

ACTUAL="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$CHECKSUM" ]; then
    echo "SQLCipher checksum mismatch: expected $CHECKSUM, got $ACTUAL" >&2
    /bin/rm -f "$ZIP"
    exit 1
fi

if [ -e "$FRAMEWORK" ]; then /bin/rm -r "$FRAMEWORK"; fi
mkdir -p "$DEST"
ditto -x -k "$ZIP" "$DEST"

codesign --verify --deep --strict "$FRAMEWORK"
if ! codesign -dv "$FRAMEWORK" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID"; then
    echo "SQLCipher framework is not signed by Zetetic (team $TEAM_ID)" >&2
    exit 1
fi

echo "$VERSION $CHECKSUM" > "$STAMP"
echo "SQLCipher $VERSION ready in Vendor/SQLCipher (checksum and Zetetic signature verified)"
