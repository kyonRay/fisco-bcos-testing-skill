#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh; source scripts/failures_lib.sh
tmp="$(mktemp -d)"
failures_append "$tmp" production-enterprise upgrade state-mismatch 高 "stateRoot差异" "T6 bump" "log.x" "3.16.4->3.17.0"
line="$(tail -1 "$tmp/failures.jsonl")"
assert_contains "$line" '"profile":"production-enterprise"' "profile field written"
assert_contains "$line" '"oracle":"state-mismatch"' "oracle field written"
assert_contains "$line" '"reported":false' "starts unreported"

# Quote-escaping: a desc containing a double quote must not break the JSON line — the embedded
# quote must come back escaped, and the line must still parse as "one JSON object per line" (no
# stray unescaped quote splitting it).
failures_append "$tmp" p2 s2 crash 中 'node said "boom" and died' "repro2" "ev2" "v2"
line2="$(tail -1 "$tmp/failures.jsonl")"
assert_contains "$line2" '\"boom\"' "embedded quote escaped"
assert_contains "$line2" '"oracle":"crash"' "second row oracle field written"

assert_done
