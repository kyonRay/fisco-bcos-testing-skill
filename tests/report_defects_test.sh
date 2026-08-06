#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh

fixture="$(mktemp -d)"
cat > "$fixture/failures.jsonl" <<'EOF'
{"profile":"production-enterprise","scenario":"upgrade","oracle":"state-mismatch","severity":"高","desc":"stateRoot差异","repro":"T6 bump","evidence":"log.x","version":"3.16.4->3.17.0","reported":false,"ts":"2026-08-06T00:00:00Z"}
{"profile":"production-enterprise","scenario":"malformed","oracle":"crash","severity":"高","desc":"node died on tampered tx","repro":"case3","evidence":"log.y","version":"3.17.0","reported":false,"ts":"2026-08-06T00:01:00Z"}
{"profile":"production-enterprise","scenario":"dual_rpc","oracle":"crash","severity":"中","desc":"already reported one","repro":"case1","evidence":"log.z","version":"3.17.0","reported":true,"ts":"2026-08-05T00:00:00Z","record_id":"rec_old"}
EOF

# Sentinel PATH shim: a fake `mcporter` that, if ever invoked, drops a marker file. --dry-run
# must never reach it — this proves the "no cloud call" claim empirically instead of just by
# code inspection.
fakebin="$(mktemp -d)"
sentinel="$fakebin/mcporter-was-called"
cat > "$fakebin/mcporter" <<EOF
#!/usr/bin/env bash
touch "$sentinel"
echo '{"records":[]}'
EOF
chmod +x "$fakebin/mcporter"

out="$(PATH="$fakebin:$PATH" bash scripts/report_defects.sh "$fixture" --dry-run)"

assert_contains "$out" "2 records to add" "dry-run reports correct unreported count (2, not the already-reported 3rd row)"
assert_contains "$out" '"file_id":"ZgGaGJqoseMl"' "dry-run JSON carries hardcoded file_id"
assert_contains "$out" '"sheet_id":"t00i2h"' "dry-run JSON carries hardcoded sheet_id"
assert_contains "$out" '"field":"画像profile"' "dry-run JSON maps profile column"
assert_contains "$out" '"option_value"' "dry-run JSON uses option_value for singleSelect columns"
assert_contains "$out" '"text_value"' "dry-run JSON uses text_value for text columns"
assert_contains "$out" '"stateRoot差异"' "dry-run JSON carries first row's desc"

if [[ -f "$sentinel" ]]; then
    echo "FAIL: --dry-run shelled out to mcporter" >&2
    _ASSERT_FAILS=1
else
    echo "ok: --dry-run never invoked mcporter"
fi

# 状态 must be "new" (a freshly auto-filed defect), not the old invalid "待处理" literal — and
# every singleSelect value this run actually emitted must fall inside its live-sheet option set.
# See tests/failures_value_labels_test.sh for the fuller regression suite (incl. gate.sh's own
# call-site literals); this is the same check scoped to report_defects.sh's own rendering logic.
assert_contains "$out" '"field":"状态","option_value":{"items":[{"text":"new"}]}}' "dry-run 状态 value is 'new'"
assert_not_contains "$out" "待处理" "dry-run JSON never emits the invalid '待处理' 状态 value"

_in_set() { local v="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$v" ]] && return 0; done; return 1; }
SCENARIO_FAMILIES=(ut dual_rpc malformed upgrade exploration baseline)
ORACLES=(crash halt fork state-mismatch)
SEVERITIES=(高 中 低)

while IFS= read -r v; do
    if _in_set "$v" "${SCENARIO_FAMILIES[@]}"; then
        echo "ok: emitted 场景族 value '$v' is a valid option"
    else
        echo "FAIL: emitted 场景族 value '$v' NOT in {${SCENARIO_FAMILIES[*]}}" >&2
        _ASSERT_FAILS=1
    fi
done < <(printf '%s' "$out" | grep -oE '"field":"场景族","option_value":\{"items":\[\{"text":"[^"]*"' | sed -E 's/.*"text":"([^"]*)"/\1/')

while IFS= read -r v; do
    if _in_set "$v" "${ORACLES[@]}"; then
        echo "ok: emitted 失败信号 value '$v' is a valid option"
    else
        echo "FAIL: emitted 失败信号 value '$v' NOT in {${ORACLES[*]}}" >&2
        _ASSERT_FAILS=1
    fi
done < <(printf '%s' "$out" | grep -oE '"field":"失败信号","option_value":\{"items":\[\{"text":"[^"]*"' | sed -E 's/.*"text":"([^"]*)"/\1/')

while IFS= read -r v; do
    if _in_set "$v" "${SEVERITIES[@]}"; then
        echo "ok: emitted 严重级别 value '$v' is a valid option"
    else
        echo "FAIL: emitted 严重级别 value '$v' NOT in {${SEVERITIES[*]}}" >&2
        _ASSERT_FAILS=1
    fi
done < <(printf '%s' "$out" | grep -oE '"field":"严重级别","option_value":\{"items":\[\{"text":"[^"]*"' | sed -E 's/.*"text":"([^"]*)"/\1/')

# -h prints usage and never touches failures.jsonl parsing / mcporter either.
out_h="$(PATH="$fakebin:$PATH" bash scripts/report_defects.sh -h)"
assert_contains "$out_h" "Usage" "help text prints usage"

assert_done
