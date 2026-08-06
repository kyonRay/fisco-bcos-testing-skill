#!/usr/bin/env bash
# Covers the parsing bug found in review: rpc_has_pending's `grep -o` count
# used to exit 1 (pipefail) on the routine zero-pending response, tripping
# set -e before oracle_liveness_decide ever ran. rpc_has_pending_parse is a
# pure string function (no IO) split out specifically so this is testable
# without a live chain — feed it synthetic RPC response bodies directly.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
# Sourcing oracle_liveness.sh must be side-effect-free: it guards its getopts
# parsing and RPC polling loop behind a BASH_SOURCE!=0 check, so this pulls
# in only the function definitions, no live-chain calls.
source scripts/oracle_liveness.sh

# Zero-match case — the routine healthy/quiescent-chain response. This is
# the exact case that used to kill the whole script under set -e; reaching
# the assert below at all is part of what's being proven.
zero_resp='{"jsonrpc":"2.0","id":1,"result":[]}'
rpc_has_pending_parse "$zero_resp" && r=pending || r=empty
assert_eq "empty" "$r" "zero-hash response does not crash and parses as no-pending"

# Non-zero case — at least one pending tx.
one_resp='{"jsonrpc":"2.0","id":1,"result":[{"hash":"0xabc","from":"0x1"}]}'
rpc_has_pending_parse "$one_resp" && r=pending || r=empty
assert_eq "pending" "$r" "one-hash response parses as pending"

# Multi-match case.
two_resp='{"jsonrpc":"2.0","id":1,"result":[{"hash":"0xabc"},{"hash":"0xdef"}]}'
rpc_has_pending_parse "$two_resp" && r=pending || r=empty
assert_eq "pending" "$r" "two-hash response parses as pending"

assert_done
