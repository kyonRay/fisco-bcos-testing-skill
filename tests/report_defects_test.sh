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

# -h prints usage and never touches failures.jsonl parsing / mcporter either.
out_h="$(PATH="$fakebin:$PATH" bash scripts/report_defects.sh -h)"
assert_contains "$out_h" "Usage" "help text prints usage"

assert_done
