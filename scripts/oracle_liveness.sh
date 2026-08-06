#!/usr/bin/env bash
# oracle_liveness.sh — consensus-halt oracle: poll a node's RPC block height
# over time and feed prev/cur/elapsed/has_pending into
# oracle_liveness_decide (scripts/oracle_lib.sh). Needs a live chain to be
# meaningful — NOT exercised by this skill's own unit tests, which cover
# oracle_liveness_decide directly as a pure function instead.
#
# Usage:
#   oracle_liveness.sh [-r rpc_url] [-t poll_interval_s] [-n samples]
#     -r  RPC URL                                        (default http://127.0.0.1:8545)
#     -t  seconds between height samples                 (default 5)
#     -n  number of samples to take before verdict        (default 2)
#     -h  print this help and exit
#
# "has_pending" is derived by probing the txpool status endpoint
# (eth_pendingTransactions count > 0); if that call fails, pending is
# conservatively assumed 1 so a genuinely stalled pool is not masked by an
# RPC hiccup.
#
# Exit status: non-zero when oracle_liveness_decide judges a stall (see
# scripts/oracle_lib.sh; threshold overridable via RG_STALL_SEC, default 30s).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/oracle_lib.sh"

RPC_URL="http://127.0.0.1:8545"
POLL_INTERVAL=5
SAMPLES=2

while getopts "r:t:n:h" opt; do
    case "$opt" in
        r) RPC_URL="$OPTARG" ;;
        t) POLL_INTERVAL="$OPTARG" ;;
        n) SAMPLES="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done

# rpc_block_number — print the current block height as a decimal integer,
# or empty string on RPC failure.
rpc_block_number() {
    local resp hex
    resp="$(curl -sS -m 10 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$RPC_URL" 2>/dev/null)" || { echo ""; return; }
    hex="$(printf '%s' "$resp" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    [[ -z "$hex" ]] && { echo ""; return; }
    printf '%d\n' "$hex"
}

# rpc_has_pending — 1 if the txpool reports pending transactions (or the
# probe fails, to avoid masking a real stall), else 0.
rpc_has_pending() {
    local resp count
    resp="$(curl -sS -m 10 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_pendingTransactions","params":[],"id":1}' \
        "$RPC_URL" 2>/dev/null)" || { echo 1; return; }
    count="$(printf '%s' "$resp" | grep -o '"hash"' | wc -l | tr -d ' ')"
    [[ -z "$count" ]] && { echo 1; return; }
    (( count > 0 )) && echo 1 || echo 0
}

prev="$(rpc_block_number)"
[[ -z "$prev" ]] && { echo "ERROR: could not read initial block height from $RPC_URL" >&2; exit 2; }
start_ts="$(date +%s)"

sample=1
while (( sample < SAMPLES )); do
    sleep "$POLL_INTERVAL"
    sample=$((sample + 1))
done

cur="$(rpc_block_number)"
[[ -z "$cur" ]] && { echo "ERROR: could not read final block height from $RPC_URL" >&2; exit 2; }
elapsed=$(( $(date +%s) - start_ts ))
has_pending="$(rpc_has_pending)"

echo "liveness: prev=$prev cur=$cur elapsed=${elapsed}s has_pending=$has_pending"
if ! oracle_liveness_decide "$prev" "$cur" "$elapsed" "$has_pending"; then
    echo "HALT: no height progress for ${elapsed}s with pending transactions"
    exit 1
fi
echo "OK: liveness"
