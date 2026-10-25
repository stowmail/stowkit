#!/usr/bin/env bash
# Builds and runs the MIME fuzz target (Fuzz/MIMEFuzz.swift) with libFuzzer
# and AddressSanitizer.
#
# Xcode's Swift refuses -sanitize=fuzzer on macOS, so this uses a swift.org
# toolchain of the same version, installed per user (no admin):
#   installer -pkg swift-<version>-RELEASE-osx.pkg -target CurrentUserHomeDirectory
# The fuzz target is compiled straight from the engine's sources and is not in
# Package.swift, so it never reaches a release build.
#
# Usage: scripts/fuzz-mime.sh [seconds]   (default 3600; extra libFuzzer flags
#        may follow, for example -jobs=4 -workers=4)
# Corpus: .build/fuzz/corpus (seeded from Tests/Fixtures/eml); crashes land in
# .build/fuzz/artifacts.

set -euo pipefail

SECONDS_TO_RUN="${1:-3600}"
shift || true
TOOLCHAIN="${STOW_FUZZ_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/fuzz"
cd "$ROOT"

if [ ! -d "$TOOLCHAIN" ]; then
    echo "No swift.org toolchain at $TOOLCHAIN (set STOW_FUZZ_TOOLCHAIN). See the comment at the top of this script." >&2
    exit 1
fi
TOOLCHAIN_ID="$(plutil -extract CFBundleIdentifier raw "$TOOLCHAIN/Info.plist")"
swiftc() { xcrun --toolchain "$TOOLCHAIN_ID" swiftc -swift-version 6 -parse-as-library -O "$@"; }

mkdir -p "$OUT/modules" "$OUT/corpus" "$OUT/artifacts"
SANITIZE=(-sanitize=fuzzer,address)

echo "==> Building StowCore"
swiftc "${SANITIZE[@]}" -module-name StowCore -emit-module -emit-module-path "$OUT/modules/StowCore.swiftmodule" \
    -emit-library -static -o "$OUT/modules/libStowCore.a" $(find Sources/StowCore -name '*.swift')

echo "==> Building the fuzz target"
swiftc "${SANITIZE[@]}" -I "$OUT/modules" -L "$OUT/modules" -lStowCore -module-name MIMEFuzz \
    Fuzz/MIMEFuzz.swift Fuzz/Shims.swift \
    Sources/StowStore/MIME/*.swift \
    Sources/StowStore/Archive/RawCompaction.swift \
    Sources/StowStore/Extraction/ZipReader.swift \
    -o "$OUT/mime-fuzz"

if [ -d Tests/Fixtures/eml ]; then
    # The 15 MiB fixture is left out: libFuzzer mutates inputs up to -max_len.
    find Tests/Fixtures/eml -name '*.eml' -size -2M -exec cp {} "$OUT/corpus/" \;
fi

echo "==> Fuzzing for $SECONDS_TO_RUN seconds"
"$OUT/mime-fuzz" "$OUT/corpus" -max_total_time="$SECONDS_TO_RUN" -max_len=262144 -timeout=10 \
    -rss_limit_mb=4096 -artifact_prefix="$OUT/artifacts/" -print_final_stats=1 "$@"
