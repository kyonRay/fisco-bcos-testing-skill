#!/usr/bin/env bash
# The [system_config_replay] section is replayed verbatim, one console call at a time, and the
# chain enforces a dependency chain on the balance flags (Features.cpp:37-46). Both halves of that
# are regression-tested here: the parser must emit keys in FILE order (an associative array alone
# gives bash hash order, which differs across machines), and the production profile's own order
# must satisfy the chain. A live run caught this — the replay died on call 1 with
# "must set feature_balance_precompiled first".
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/profile_lib.sh

PROF=profiles/production-enterprise.profile
profile_load "$PROF"

# Expected order is re-derived from the file itself rather than hardcoded, so this test cannot go
# stale when the captured profile is re-captured with different flags.
expected="$(sed -n '/^\[system_config_replay\]/,/^\[config_ini_override\]/p' "$PROF" \
    | grep -E '^[a-zA-Z_][a-zA-Z0-9_]* *=' | sed -E 's/ *=.*//')"
actual="$(profile_replay_pairs | awk '{print $1}')"
assert_eq "$expected" "$actual" "replay pairs emitted in profile file order"

config_expected="$(sed -n '/^\[config_ini_override\]/,$p' "$PROF" \
    | grep -E '^[a-zA-Z_][a-zA-Z0-9_.]* *=' | sed -E 's/ *=.*//')"
config_actual="$(profile_config_pairs | awk '{print $1}')"
assert_eq "$config_expected" "$config_actual" "config pairs emitted in profile file order"

# The dependency chain itself: feature_balance -> feature_balance_precompiled ->
# feature_balance_policy1 (Features.cpp:37-46). Compare line positions in the emitted order.
pos() { printf '%s\n' "$actual" | grep -nx "$1" | cut -d: -f1; }
bal="$(pos feature_balance)"
pre="$(pos feature_balance_precompiled)"
pol="$(pos feature_balance_policy1)"
assert_eq "1" "$([[ -n "$bal" && -n "$pre" && $bal -lt $pre ]] && echo 1 || echo 0)" \
    "feature_balance replayed before feature_balance_precompiled (Features.cpp:37-41)"
assert_eq "1" "$([[ -n "$pre" && -n "$pol" && $pre -lt $pol ]] && echo 1 || echo 0)" \
    "feature_balance_precompiled replayed before feature_balance_policy1 (Features.cpp:42-46)"

# auth_check_status must be replayed LAST: it switches committee governance on, after which every
# direct setSystemConfigByKey is rejected with {"code":-50000,"msg":"Permission denied"} and has to
# go through setSysConfigProposal instead. A live run lost its final key to exactly this.
total="$(printf '%s\n' "$actual" | grep -c .)"
auth="$(pos auth_check_status)"
if [[ -n "$auth" ]]; then
    assert_eq "$total" "$auth" "auth_check_status is the LAST replayed key (governance locks out later direct sets)"
fi

assert_done
