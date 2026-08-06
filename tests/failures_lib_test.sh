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

# _gate_scenario_label: gate.sh's run_oracles_once phase label -> valid 场景族 option (see
# tests/failures_value_labels_test.sh for the full value/option-set regression suite; this is
# just the direct unit test of the normalization function itself, right where it's defined).
assert_eq "ut" "$(_gate_scenario_label "after:ut")" "after:ut -> ut"
assert_eq "dual_rpc" "$(_gate_scenario_label "after:dual_rpc")" "after:dual_rpc -> dual_rpc"
assert_eq "baseline" "$(_gate_scenario_label "baseline")" "baseline passes through unchanged"

assert_done
