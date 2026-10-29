#!/usr/bin/env bash
# Builds and runs one libFuzzer target from Fuzz/ with AddressSanitizer
# (Phase 4, security sweep 1 R-02, D-499).
#
# Xcode's Swift refuses -sanitize=fuzzer on macOS, so this uses a swift.org
# toolchain of the same version, installed per user (no admin):
#   installer -pkg swift-<version>-RELEASE-osx.pkg -target CurrentUserHomeDirectory
# Each target is compiled straight from the engine's sources and is not in
# Package.swift, so it never reaches a release build.
#
# Usage: scripts/fuzz.sh <target> [seconds] [libFuzzer flags...]
#   targets: mime, html, words, query, zip, imap   (default 3600 seconds)
# Corpus: .build/fuzz/<target>/corpus, seeded from the fixtures and from the
# large hostile inputs of the A-01 and A-02 timing tests; findings land in
# .build/fuzz/<target>/artifacts. A unit slower than -timeout is a finding,
# which is how a quadratic path shows up.

set -euo pipefail

TARGET="${1:?usage: scripts/fuzz.sh <mime|html|words|query|zip|imap> [seconds] [libFuzzer flags...]}"
SECONDS_TO_RUN="${2:-3600}"
shift $(( $# < 2 ? $# : 2 ))
TOOLCHAIN="${STOW_FUZZ_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FUZZ="$ROOT/.build/fuzz"
OUT="$FUZZ/$TARGET"
cd "$ROOT"

if [ ! -d "$TOOLCHAIN" ]; then
    echo "No swift.org toolchain at $TOOLCHAIN (set STOW_FUZZ_TOOLCHAIN). See the comment at the top of this script." >&2
    exit 1
fi
TOOLCHAIN_ID="$(plutil -extract CFBundleIdentifier raw "$TOOLCHAIN/Info.plist")"
swiftc() { xcrun --toolchain "$TOOLCHAIN_ID" swiftc -swift-version 6 -parse-as-library -O "$@"; }
SANITIZE=(-sanitize=fuzzer,address)
mkdir -p "$FUZZ/modules" "$OUT/corpus" "$OUT/artifacts"

build_stowcore() {
    echo "==> Building StowCore"
    swiftc "${SANITIZE[@]}" -module-name StowCore -emit-module -emit-module-path "$FUZZ/modules/StowCore.swiftmodule" \
        -emit-library -static -o "$FUZZ/modules/libStowCore.a" $(find Sources/StowCore -name '*.swift')
}
with_stowcore=(-I "$FUZZ/modules" -L "$FUZZ/modules" -lStowCore)

# Module maps of the C targets swift-nio needs, for importing its Swift modules.
c_module_flags() {
    { find "$1/checkouts" -path '*/Sources/*/include/module.modulemap'
      find "$1/out/Intermediates.noindex/GeneratedModuleMaps" -name '*.modulemap'; } | while read -r map; do
        printf -- '-Xcc -fmodule-map-file=%s ' "$map"
    done
}

# The A-01 and A-02 inputs from the timing tests, at 1 MB, as seeds.
seed() { perl -e 'print $ARGV[0] x int($ARGV[1] / length $ARGV[0]); print $ARGV[2] // ""' "$@"; }
seed_html() {
    seed '<a' 1048576 > "$OUT/corpus/seed-unclosed-tags"
    { seed '<a b="c"' 786432 '<i title="'; seed '<b>' 65536 'end'; } > "$OUT/corpus/seed-unclosed-quote"
    { printf 'Hello <script>'; seed '<a' 1048576; } > "$OUT/corpus/seed-unclosed-script"
}
seed_words() {
    seed '=?' 1048576 > "$OUT/corpus/seed-markers"
    seed '=?x?' 1048576 > "$OUT/corpus/seed-charset-only"
    seed '=?a?q?x' 1048576 > "$OUT/corpus/seed-text-never-ends"
    printf '=?utf-8?q?caf=C3=A9?= =?UTF-8?B?Y2Fmw6k=?=' > "$OUT/corpus/seed-valid"
    printf 'a\r\nb' > "$OUT/corpus/seed-crlf"  # A-22: once looped forever
}

case "$TARGET" in
mime)
    build_stowcore
    echo "==> Building the mime target"
    swiftc "${SANITIZE[@]}" "${with_stowcore[@]}" -module-name MIMEFuzz \
        Fuzz/MIMEFuzz.swift Fuzz/Shims.swift Sources/StowStore/MIME/*.swift \
        Sources/StowStore/Archive/RawCompaction.swift Sources/StowStore/Extraction/ZipReader.swift \
        Sources/StowStore/Extraction/TextExtractor.swift \
        -o "$OUT/fuzz"
    # The 15 MiB fixture is left out: libFuzzer mutates inputs up to -max_len.
    if [ -d Tests/Fixtures/eml ]; then find Tests/Fixtures/eml -name '*.eml' -size -2M -exec cp {} "$OUT/corpus/" \; ; fi
    { printf 'From: a@example.org\r\nSubject: '; seed '=?' 262144; printf '\r\nContent-Type: text/html\r\n\r\n'; seed '<a' 524288; } \
        > "$OUT/corpus/seed-hostile-message"
    MAX_LEN=1048576
    ;;
html)
    echo "==> Building the html target"
    swiftc "${SANITIZE[@]}" -module-name HTMLTextFuzz Fuzz/HTMLTextFuzz.swift Sources/StowStore/MIME/HTMLText.swift -o "$OUT/fuzz"
    seed_html
    MAX_LEN=1048576
    ;;
words)
    build_stowcore
    echo "==> Building the words target"
    swiftc "${SANITIZE[@]}" "${with_stowcore[@]}" -module-name EncodedWordsFuzz \
        Fuzz/EncodedWordsFuzz.swift Sources/StowStore/MIME/ContentFields.swift -o "$OUT/fuzz"
    seed_words
    MAX_LEN=1048576
    ;;
query)
    build_stowcore
    echo "==> Building the query target"
    swiftc "${SANITIZE[@]}" "${with_stowcore[@]}" -module-name QueryParserFuzz \
        Fuzz/QueryParserFuzz.swift Sources/StowSearch/QueryParser.swift -o "$OUT/fuzz"
    printf 'invoice from:acme has:attachment after:2024-01-01 "exact phrase" pre* a OR b -c in:"Project X"' > "$OUT/corpus/seed-query"
    MAX_LEN=65536
    ;;
zip)
    echo "==> Building the zip target"
    swiftc "${SANITIZE[@]}" -module-name ZipReaderFuzz Fuzz/ZipReaderFuzz.swift Sources/StowStore/Extraction/ZipReader.swift -o "$OUT/fuzz"
    if [ -d Tests/Fixtures/eml ]; then
        # A real .docx, decoded from the fixture that carries one.
        perl -0777 -ne 'print $1 if /filename="[^"]*\.docx".*?\r?\n\r?\n(.*?)\r?\n--/s' Tests/Fixtures/eml/09-docx.eml \
            | base64 -D > "$OUT/corpus/seed-docx" 2>/dev/null || true
    fi
    MAX_LEN=1048576
    ;;
imap)
    build_stowcore
    # swift-nio-imap and its dependencies, built by SwiftPM with the fuzz
    # toolchain into their own folder; only the NIOIMAPCore target and what it needs.
    echo "==> Building swift-nio-imap with the fuzz toolchain"
    SPM="$FUZZ/spm"
    xcrun --toolchain "$TOOLCHAIN_ID" swift build --scratch-path "$SPM" -c release --target NIOIMAPCore \
        -Xswiftc -sanitize=fuzzer,address
    echo "==> Building the imap target"
    swiftc "${SANITIZE[@]}" "${with_stowcore[@]}" -I "$SPM/release" -I "$SPM/release/Modules" $(c_module_flags "$SPM") \
        -module-name IMAPFuzz Fuzz/IMAPFuzz.swift Fuzz/IMAPShims.swift \
        Sources/StowSync/IMAP/FetchAssembler.swift Sources/StowSync/IMAP/IMAPTypes.swift Sources/StowSync/SyncError.swift \
        "$SPM"/release/*.o -o "$OUT/fuzz"
    printf '* 1 FETCH (UID 1 RFC822.SIZE 12 FLAGS (\\Seen) BODY[] {12}\r\nSubject: x\r\n)\r\nS1 OK done\r\n' > "$OUT/corpus/seed-fetch"
    MAX_LEN=1048576
    ;;
*)
    echo "Unknown target $TARGET" >&2
    exit 1
    ;;
esac

echo "==> Fuzzing $TARGET for $SECONDS_TO_RUN seconds"
"$OUT/fuzz" "$OUT/corpus" -max_total_time="$SECONDS_TO_RUN" -max_len="$MAX_LEN" -timeout=5 \
    -rss_limit_mb=4096 -artifact_prefix="$OUT/artifacts/" -print_final_stats=1 "$@"
