#!/usr/bin/env bash
# Points git at the versioned hooks in scripts/hooks. Applies to every worktree.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath scripts/hooks
echo "Hooks installed: $(git config core.hooksPath)"
