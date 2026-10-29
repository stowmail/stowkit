#!/usr/bin/env bash
# Build, test and secret-scan the engine. Must pass before every commit.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/fetch-sqlcipher.sh

if [ ! -f Tests/Fixtures/eml/manifest.json ] || [ scripts/make-fixtures.swift -nt Tests/Fixtures/eml/manifest.json ]; then
    echo "==> Generating fixtures"
    scripts/make-fixtures
fi

echo "==> swift build"
swift build

echo "==> swift test"
swift test

# The benchmarks run in release with -enable-testing; keep that building.
echo "==> swift build -c release --build-tests"
swift build -c release -Xswiftc -enable-testing --build-tests

echo "==> gitleaks (committed history)"
if git rev-parse --verify HEAD >/dev/null 2>&1; then
    gitleaks git --redact --no-banner .
else
    echo "No commits yet."
fi

echo "==> gitleaks (staged changes)"
gitleaks git --pre-commit --staged --redact --no-banner .

echo "All checks passed."
