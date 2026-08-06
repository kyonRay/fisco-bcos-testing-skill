#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/scenarios/scenario_upgrade.sh

assert_eq "0" "$(type -t scenario_upgrade_run > /dev/null && echo 0 || echo 1)" "scenario_upgrade_run defined"
assert_eq "0" "$(type -t _upg_no_fork > /dev/null && echo 0 || echo 1)" "_upg_no_fork defined"
assert_eq "0" "$(type -t _upg_flag_flipped > /dev/null && echo 0 || echo 1)" "_upg_flag_flipped defined"

# Pure decision functions only (no IO) — the ONLY part of scenario_upgrade.sh exercised here,
# other than the file-read-only flag-derivation helper below. scenario_upgrade_run itself needs a
# live cluster + real fisco-bcos binaries and is NOT exercised by this test (see that function's
# own header comment).
#
# _upg_no_fork "<h> <hash>" "<h> <hash>" "<h> <hash>": pass when no same-height pair disagrees on
# hash; fail (fork caught) the moment one does. `if` guards every call (rather than
# `cmd && ... || ...` at top level) so a deliberately-failing case doesn't trip this test script's
# own `set -e`, matching scenario_dual_rpc_test.sh / scenario_malformed_test.sh's convention.

if _upg_no_fork "100 0xAA" "100 0xAA" "100 0xAA"; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "_upg_no_fork: three nodes agree on height+hash -> no fork"

if _upg_no_fork "100 0xAA" "100 0xBB" "100 0xAA"; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "_upg_no_fork: same height, one node's hash differs -> fork caught"

if _upg_no_fork "100 0xAA" "99 0xAA" "100 0xAA"; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "_upg_no_fork: different heights (one still catching up) is not by itself a fork"

# _upg_flag_flipped <before> <after>: pass ONLY IF before was off (null/empty) AND after is on
# ("1"); every other combination (including "was already on", "still off after") fails.

if _upg_flag_flipped "null" "1"; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "_upg_flag_flipped: null -> 1 is a clean flip"

if _upg_flag_flipped "null" "null"; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "_upg_flag_flipped: still null after bump -> not flipped, caught"

if _upg_flag_flipped "" "1"; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "_upg_flag_flipped: empty (treated same as null) -> 1 is a clean flip"

if _upg_flag_flipped "1" "1"; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "_upg_flag_flipped: already on before the bump -> not this scenario's flip, fails"

# _upg_target_flags <target_ver> <features_cpp>: file-read-only (no network, no running chain) —
# parses THIS checkout's own bcos-framework/bcos-framework/ledger/Features.cpp, so it is
# hermetically testable against ground truth rather than a fixture, per the "facts don't get
# baked in" editing invariant. Assert against the real setUpgradeFeatures() upgradeRoadmap table's
# 3.17.0 entry, not a fixed list copied into this test — if that table's line moves this test
# still reads the same block, and if the set of flags for 3.17.0 changes upstream, this test
# should be re-derived from the same source rather than hand-edited to match.
repo_root="$(_upg_find_repo_root)"
features_cpp="$repo_root/bcos-framework/bcos-framework/ledger/Features.cpp"
if [[ -f "$features_cpp" ]]; then
    out="$(_upg_target_flags 3.17.0 "$features_cpp")"
    assert_contains "$out" "bugfix_auth_check" "_upg_target_flags(3.17.0): includes bugfix_auth_check"
    assert_contains "$out" "bugfix_nonce_ordering" "_upg_target_flags(3.17.0): includes bugfix_nonce_ordering"
    assert_not_contains "$out" "bugfix_revert_logs" "_upg_target_flags(3.17.0): does NOT include a 3.16.4-only flag"

    out2="$(_upg_target_flags 3.16.4 "$features_cpp")"
    assert_eq "bugfix_revert_logs" "$out2" "_upg_target_flags(3.16.4): exactly the single flag that version's table entry lists"
else
    echo "SKIP: Features.cpp not found at $features_cpp (not inside a full FISCO-BCOS checkout) — skipping _upg_target_flags live-source assertions"
fi

# SCENARIO_DRY=1 prints the T0-T8 plan without sending anything — no live chain needed, so this
# branch (unlike scenario_upgrade_run's real-run branch) IS hermetic and safe to exercise here.
# Mirrors scenario_ut_test.sh / scenario_dual_rpc_test.sh / scenario_malformed_test.sh's own
# dry-output assertion style.
out="$(SCENARIO_DRY=1 scenario_upgrade_run /tmp/x /tmp/old-bin /tmp/new-bin 3.17.0)"
assert_contains "$out" "T0" "dry output lists T0 (reproduce prod)"
assert_contains "$out" "_upg_no_fork" "dry output lists the T2-T4 no-fork check"
assert_contains "$out" "compatibility_version 3.17.0" "dry output lists the T5 version bump with the requested target"
assert_contains "$out" "_upg_flag_flipped" "dry output lists the T6 flag-flip check"
assert_contains "$out" "T8" "dry output lists the optional T8 rollback step"
assert_not_contains "$out" "ERROR" "dry output reports no errors (confirms nothing was actually sent)"

assert_done
