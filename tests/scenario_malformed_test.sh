#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/scenarios/scenario_malformed.sh

assert_eq "0" "$(type -t scenario_malformed_run > /dev/null && echo 0 || echo 1)" "scenario_malformed_run defined"
assert_eq "0" "$(type -t _mal_verdict > /dev/null && echo 0 || echo 1)" "_mal_verdict defined"

# Pure false-green-guard function only (no IO). This is the ONLY part of scenario_malformed.sh
# exercised here — scenario_malformed_run itself needs a live cluster + a TAMPER_HELPER and is
# NOT exercised by this test (see that function's own header comment).
#
# _mal_verdict <rpc_rejected> <node_alive>: pass (clean reject) ONLY IF rejected==1 AND
# alive==1. A crash disguised as a rejection (rejected==1 but alive==0) MUST fail — that's the
# exact false-green this scenario guards against.

if _mal_verdict 1 1; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "_mal_verdict: rejected+alive (1,1) -> clean reject (pass)"

if _mal_verdict 1 0; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "_mal_verdict: rejected+DEAD (1,0) -> false-green caught (fail), even though 'rejected'"

if _mal_verdict 0 1; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "_mal_verdict: NOT rejected+alive (0,1) -> fail (malformed tx was accepted)"

if _mal_verdict 0 0; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "_mal_verdict: NOT rejected+dead (0,0) -> fail"

# SCENARIO_DRY=1 lists the case plan without sending anything — no live chain needed, so this
# branch (unlike scenario_malformed_run's real-run branch) IS hermetic and safe to exercise here.
# Mirrors scenario_ut_test.sh / scenario_dual_rpc_test.sh's own dry-output assertion style.
out="$(SCENARIO_DRY=1 scenario_malformed_run /tmp/x)"
assert_contains "$out" "positive control" "dry output lists the positive-control step"
assert_contains "$out" "oracle_crash" "dry output lists the oracle_crash liveness probe step"
assert_contains "$out" "_mal_verdict" "dry output lists the verdict step"
assert_not_contains "$out" "ERROR" "dry output reports no errors (confirms nothing was actually sent)"

assert_done
