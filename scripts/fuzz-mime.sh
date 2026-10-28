#!/usr/bin/env bash
# Kept so older notes still work: the same as `scripts/fuzz.sh mime [seconds] [libFuzzer flags...]`.
exec "$(dirname "$0")/fuzz.sh" mime "$@"
