#!/bin/sh
# The one place this repository's checks are defined. The commit hook and CI both call it.
# Usage: ./scripts/check.sh [--fast]    --fast skips the tests.
set -eu
cd "$(dirname "$0")/.."

scarb fmt --check
scarb lint --test --deny-warnings
scarb build

if [ "${1:-}" = "--fast" ]; then
    exit 0
fi

# snforge exits 0 when it finds no tests, so a suite that is not declared from
# tests/lib.cairo disappears silently. Require at least one passing test.
out=$(mktemp)
trap 'rm -f "$out"' EXIT
snforge test | tee "$out"
if ! grep -Eq 'Tests: [1-9][0-9]* passed' "$out"; then
    echo "check: snforge ran no passing tests" >&2
    exit 1
fi
