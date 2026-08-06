#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/scenarios/scenario_dual_rpc.sh

assert_eq "0" "$(type -t scenario_dual_rpc_run > /dev/null && echo 0 || echo 1)" "scenario_dual_rpc_run defined"
assert_eq "0" "$(type -t _drpc_assert_receipt > /dev/null && echo 0 || echo 1)" "_drpc_assert_receipt defined"
assert_eq "0" "$(type -t _drpc_assert_return > /dev/null && echo 0 || echo 1)" "_drpc_assert_return defined"

# Pure comparison functions only, exactly as scripts/scenarios/scenario_dual_rpc.sh defines them
# (no IO). scenario_dual_rpc_run itself needs a live BCOS RPC (:20200) + Web3 RPC (:8545) cluster
# to do anything and is NOT exercised here — see that function's own header comment. `if` guards
# every call below (rather than `cmd && ... || ...` at top level) so a deliberately-failing
# comparison doesn't trip this test script's own `set -e`.

if _drpc_assert_receipt 0 0; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "_drpc_assert_receipt: matching status (0,0) returns success"

if _drpc_assert_receipt 0 1; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "_drpc_assert_receipt: mismatched status (0,1) returns failure"

if _drpc_assert_return 0x2a 0x2a; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "_drpc_assert_return: matching value (0x2a,0x2a) returns success"

if _drpc_assert_return 0x00 0x2a; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "_drpc_assert_return: mismatched value (0x00,0x2a) returns failure"

assert_done
