#!/usr/bin/env bash
# _jsd_verdict is the whole point of this scenario: java-sdk-demo's DMC demos exit 0 even after
# printing per-transaction failures, so "$? == 0" alone would pass a run that lost transactions.
# The verdict therefore also demands the end-of-run balance-conservation line and a zero error
# tally. Fixtures below are verbatim tails from real runs against a live production-profile chain.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/scenarios/scenario_jsd.sh

assert_eq "0" "$(type -t scenario_jsd_run >/dev/null && echo 0 || echo 1)" "function defined"
assert_eq "scenario_jsd_run" "${GATE_SCENARIOS[jsd]}" "registered into GATE_SCENARIOS"

# Real tails. Note the punctuation around the marker differs per class — hence matching the phrase
# rather than a whole line.
DAG_OK='Avg time cost: 378ms
Errors: 0
Sending transactions finished!
check finished, total balance equal expectBalance!'
MYSELF_OK='400  < time <  1000ms : 11  : 55.00000000000001%
check finished! check finished, total balance equal expectBalance! '
STAR_OK='Sending transactions finished!
check finished, total balance equal expectBalance !'

for name in DAG MYSELF STAR; do
    eval "body=\$${name}_OK"
    _jsd_verdict 0 "$body" && r=0 || r=1
    assert_eq "0" "$r" "$name success tail passes the verdict"
done

# Negative controls — each must FAIL, and each isolates one failure mode.
NOT_ENOUGH_CASH='Deploy contract[8] failed: Not enough cash
ContractException{responseOutput=null, errorCode=7}
ERROR: 9 contract(s) failed to deploy. Aborting test to avoid NPE and misleading results.'
_jsd_verdict 1 "$NOT_ENOUGH_CASH" && r=0 || r=1
assert_eq "1" "$r" "non-zero exit fails the verdict"

# Exit 0 but the run never reached its balance check — the case a bare \$? test would wave through.
_jsd_verdict 0 'Sending transactions finished!' && r=0 || r=1
assert_eq "1" "$r" "exit 0 without the balance-conservation line fails the verdict"

# Exit 0 and the balance line present, but transactions errored — also a fail.
_jsd_verdict 0 'Errors: 3
check finished, total balance equal expectBalance!' && r=0 || r=1
assert_eq "1" "$r" "non-zero Errors tally fails the verdict even with the balance line"

# Dry mode must plan every class x DAG-mode combination and touch nothing.
out="$(SCENARIO_DRY=1 scenario_jsd_run /tmp/x)"
for cls in DMCTransferDag DMCTransferMyself DMCTransferStar; do
    assert_contains "$out" "$cls" "dry run plans $cls"
done
assert_contains "$out" "true" "dry run plans a DAG-on pass"
assert_contains "$out" "false" "dry run plans a DAG-off pass"
assert_eq "6" "$(printf '%s\n' "$out" | grep -c 'org.fisco.bcos.sdk.demo.perf')" "3 classes x 2 DAG modes = 6 planned runs"

# A real run without JSD_DIR must FAIL, never silently skip: absent load coverage is not evidence
# of health (same rule scenario_ut now follows for absent UT binaries).
rc_real=0
JSD_DIR="" scenario_jsd_run /tmp/x >/dev/null 2>&1 || rc_real=$?
assert_eq "1" "$rc_real" "real run without JSD_DIR fails rather than passing on no coverage"

assert_done
