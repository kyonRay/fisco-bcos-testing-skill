#!/usr/bin/env bash
# Regression guard for the value/label-match bugs found in review: gate.sh's failures_append
# call sites and report_defects.sh's column mapping must only ever emit values that are actual
# options on the live smartsheet's 5 singleSelect columns. The sheet's option sets are
# authoritative (not derived from this repo) — hardcode them here from the reviewer's fix
# instructions and check every emitted value against them.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/failures_lib.sh

_in_set() {  # value set-member...
    local v="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$v" ]] && return 0; done
    return 1
}

# Known-good option sets, per the live sheet (coordinator's fix instructions).
SCENARIO_FAMILIES=(ut dual_rpc malformed upgrade exploration baseline)
ORACLES=(crash halt fork state-mismatch)
SEVERITIES=(高 中 低)
STATUSES=(new triaged fixed regression-added)
PROFILE_BASENAMES=(default-latest evm-full production-enterprise rpbft-scale sm-gov upgrade-legacy)

# --- CRITICAL #1 regression guard: _gate_scenario_label phase -> family normalization --------
assert_eq "ut" "$(_gate_scenario_label "after:ut")" "after:ut -> ut"
assert_eq "dual_rpc" "$(_gate_scenario_label "after:dual_rpc")" "after:dual_rpc -> dual_rpc"
assert_eq "malformed" "$(_gate_scenario_label "after:malformed")" "after:malformed -> malformed"
assert_eq "upgrade" "$(_gate_scenario_label "after:upgrade")" "after:upgrade -> upgrade"
assert_eq "baseline" "$(_gate_scenario_label "baseline")" "baseline passes through unchanged"

for family in ut dual_rpc malformed upgrade baseline; do
    phase="after:$family"; [[ "$family" == baseline ]] && phase="baseline"
    label="$(_gate_scenario_label "$phase")"
    if _in_set "$label" "${SCENARIO_FAMILIES[@]}"; then
        echo "ok: _gate_scenario_label('$phase') = '$label' is a valid 场景族 option"
    else
        echo "FAIL: _gate_scenario_label('$phase') = '$label' NOT in {${SCENARIO_FAMILIES[*]}}" >&2
        _ASSERT_FAILS=1
    fi
done

# --- IMPORTANT + CRITICAL #1 regression guard: gate.sh's actual failures_append call sites ---
# Static check on gate.sh's own source (its real-run path needs a live chain this environment
# doesn't have, so this is the only way to exercise the exact literals gate.sh will emit). Pulls
# each failures_append call's 4th positional arg (oracle) and 5th (severity) and checks both
# against the sheet's option sets. This is exactly the check that would have caught the original
# hardcoded "consensus-halt".
mapfile -t oracle_literals < <(grep 'failures_append "\$FAILURES_OUTDIR" "\$profile_name" "\$scenario_label"' scripts/gate.sh \
    | sed -E 's/.*"\$scenario_label" "([a-z-]+)" "[^"]+".*/\1/')
mapfile -t severity_literals < <(grep 'failures_append "\$FAILURES_OUTDIR" "\$profile_name" "\$scenario_label"' scripts/gate.sh \
    | sed -E 's/.*"\$scenario_label" "[a-z-]+" "([^"]+)".*/\1/')

assert_eq "3" "${#oracle_literals[@]}" "gate.sh has exactly 3 failures_append call sites (crash/liveness/stateroot)"

for oracle_lit in "${oracle_literals[@]}"; do
    if _in_set "$oracle_lit" "${ORACLES[@]}"; then
        echo "ok: gate.sh oracle literal '$oracle_lit' is a valid 失败信号 option"
    else
        echo "FAIL: gate.sh oracle literal '$oracle_lit' NOT in {${ORACLES[*]}}" >&2
        _ASSERT_FAILS=1
    fi
done
# The liveness oracle specifically must be "halt", not the old "consensus-halt" — pin it by name
# so a future edit that reintroduces the invalid literal fails loudly and specifically.
assert_contains "${oracle_literals[*]}" "halt" "liveness oracle literal is 'halt' (not 'consensus-halt')"
assert_not_contains "${oracle_literals[*]}" "consensus-halt" "liveness oracle literal is NOT the invalid 'consensus-halt'"

for severity_lit in "${severity_literals[@]}"; do
    if _in_set "$severity_lit" "${SEVERITIES[@]}"; then
        echo "ok: gate.sh severity literal '$severity_lit' is a valid 严重级别 option"
    else
        echo "FAIL: gate.sh severity literal '$severity_lit' NOT in {${SEVERITIES[*]}}" >&2
        _ASSERT_FAILS=1
    fi
done

# --- 画像profile: every real profile's derived basename must be a valid option ---------------
for f in profiles/*.profile; do
    base="$(basename "$f")"
    name="${base%.*}"
    if _in_set "$name" "${PROFILE_BASENAMES[@]}"; then
        echo "ok: profile basename '$name' is a valid 画像profile option"
    else
        echo "FAIL: profile basename '$name' NOT in {${PROFILE_BASENAMES[*]}}" >&2
        _ASSERT_FAILS=1
    fi
done

# --- CRITICAL #2 regression guard: report_defects.sh's 状态 literal ---------------------------
if grep -q '_rd_field_option "状态" "new"' scripts/report_defects.sh; then
    echo "ok: report_defects.sh's 状态 literal is 'new'"
else
    echo "FAIL: report_defects.sh's 状态 literal is not 'new' (expected _rd_field_option \"状态\" \"new\")" >&2
    _ASSERT_FAILS=1
fi
if grep -q '"状态" "待处理"' scripts/report_defects.sh; then
    echo "FAIL: report_defects.sh still contains the invalid '待处理' 状态 literal" >&2
    _ASSERT_FAILS=1
else
    echo "ok: report_defects.sh no longer contains the invalid '待处理' 状态 literal"
fi
assert_contains "${STATUSES[*]}" "new" "'new' is itself a valid 状态 option (sanity check on the known-set constant)"

# --- End-to-end: report_defects.sh --dry-run, fed values shaped exactly like gate.sh's real
# call-site output (normalized scenario_label, oracle from the valid set), must render 状态="new"
# and keep every singleSelect value inside its known option set. This is the integration gap the
# original tests missed: report_defects_test.sh's fixture used hand-written already-valid values
# and never exercised gate.sh's actual (buggy, at the time) call-site values.
fixture="$(mktemp -d)"
scenario_label="$(_gate_scenario_label "after:ut")"
failures_append "$fixture" production-enterprise "$scenario_label" "halt" "高" "d1" "r1" "e1" "v1"
out="$(bash scripts/report_defects.sh "$fixture" --dry-run)"

assert_contains "$out" '"field":"状态","option_value":{"items":[{"text":"new"}]}}' "dry-run 状态 value is 'new'"
assert_contains "$out" '"field":"场景族","option_value":{"items":[{"text":"ut"}]}}' "dry-run 场景族 value is normalized 'ut', not 'after:ut'"
assert_not_contains "$out" "after:ut" "dry-run JSON never contains the raw 'after:ut' phase label"

assert_done
