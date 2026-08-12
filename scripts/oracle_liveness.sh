#!/usr/bin/env bash
# oracle_liveness.sh — consensus-halt oracle: poll a node's RPC block height
# over time and feed prev/cur/elapsed/has_pending into
# oracle_liveness_decide (scripts/oracle_lib.sh). Needs a live chain to be
# meaningful — NOT exercised by this skill's own unit tests as a whole
# script; oracle_liveness_decide itself is covered directly as a pure
# function, and rpc_has_pending_parse (below) is covered directly too since
# it takes a response string and does no IO — see
# tests/oracle_liveness_parse_test.sh, which sources this file (safe: see
# the execution guard at the bottom) without needing a live chain.
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
# RPC hiccup. The routine, healthy case is zero pending transactions — that
# path must not be treated as a probe failure (see rpc_has_pending_parse).
#
# Exit status: non-zero when oracle_liveness_decide judges a stall (see
# scripts/oracle_lib.sh; threshold overridable via RG_STALL_SEC, default 30s).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/oracle_lib.sh"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
SAMPLES="${SAMPLES:-2}"

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

# rpc_has_pending_parse <json_response> — pure parse, no IO: return status 0
# (true/"has pending") if the response contains at least one pending-tx
# entry, status 1 (false/"no pending") otherwise. Zero matches is the
# routine, healthy quiescent-chain case and must NOT be conflated with an
# RPC/parse failure — that distinction is why this is split out of
# rpc_has_pending (the IO wrapper), so it can be fed a synthetic response
# string and unit-tested without a live chain.
#
# `grep -o` exits 1 on zero matches; under `set -o pipefail` that makes the
# whole `grep | wc | tr` pipeline's status 1, which would trip `set -e` if
# this assignment weren't guarded — the `|| count=0` below is load-bearing,
# not defensive decoration.
rpc_has_pending_parse() {
    local resp="$1" count
    count="$(printf '%s' "$resp" | grep -o '"hash"' | wc -l | tr -d ' ')" || count=0
    [[ -z "$count" ]] && count=0
    (( count > 0 ))
}

# rpc_has_pending — 1 if the txpool reports pending transactions (or the
# probe fails, to avoid masking a real stall), else 0.
rpc_has_pending() {
    local resp
    resp="$(curl -sS -m 10 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_pendingTransactions","params":[],"id":1}' \
        "$RPC_URL" 2>/dev/null)" || { echo 1; return; }
    if rpc_has_pending_parse "$resp"; then
        echo 1
    else
        echo 0
    fi
}

# ---------------------------------------------------------------------------
# Main — only runs when this file is executed directly, not when sourced.
# Sourcing (e.g. from tests/oracle_liveness_parse_test.sh) must only pick up
# the function definitions above, never the getopts parsing or the live-RPC
# polling flow below, which would exit/error out with no chain listening.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    while getopts "r:t:n:h" opt; do
        case "$opt" in
            r) RPC_URL="$OPTARG" ;;
            t) POLL_INTERVAL="$OPTARG" ;;
            n) SAMPLES="$OPTARG" ;;
            h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "bad flag; -h for help" >&2; exit 2 ;;
        esac
    done

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
fi
