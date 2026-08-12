#!/usr/bin/env bash
# oracle_stateroot.sh — state-mismatch oracle: fetch the stateRoot for a
# given block height from each of one or more nodes' RPC endpoints and feed
# them into oracle_stateroot_decide (scripts/oracle_lib.sh). Needs a live
# multi-node chain to be meaningful — NOT exercised by this skill's own unit
# tests, which cover oracle_stateroot_decide directly as a pure function
# instead.
#
# Usage:
#   oracle_stateroot.sh -b <height> -r <rpc_url> [-r <rpc_url> ...]
#     -b  block height (decimal) to compare stateRoot at   (required)
#     -r  RPC URL, repeatable — at least 2 needed for a comparison to be
#         meaningful (required, at least once)
#     -h  print this help and exit
#
# Exit status: non-zero when oracle_stateroot_decide finds a divergence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/oracle_lib.sh"

HEIGHT=""
RPC_URLS=()

while getopts "b:r:h" opt; do
    case "$opt" in
        b) HEIGHT="$OPTARG" ;;
        r) RPC_URLS+=("$OPTARG") ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done

[[ -z "$HEIGHT" ]] && { echo "ERROR: -b <height> is required. -h for help." >&2; exit 2; }
[[ ${#RPC_URLS[@]} -ge 1 ]] || { echo "ERROR: at least one -r <rpc_url> is required. -h for help." >&2; exit 2; }

# rpc_state_root <rpc_url> <height> — print the stateRoot hex for a block,
# or empty string on RPC failure.
rpc_state_root() {
    local url="$1" height="$2" hex resp root
    hex="$(printf '0x%x' "$height")"
    resp="$(curl -sS -m 10 \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$hex\",false],\"id\":1}" \
        "$url" 2>/dev/null)" || { echo ""; return; }
    root="$(printf '%s' "$resp" | sed -n 's/.*"stateRoot":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    echo "$root"
}

roots=()
for url in "${RPC_URLS[@]}"; do
    root="$(rpc_state_root "$url" "$HEIGHT")"
    [[ -z "$root" ]] && { echo "ERROR: could not read stateRoot at height $HEIGHT from $url" >&2; exit 2; }
    echo "stateroot: $url -> $root"
    roots+=("$root")
done

if [[ ${#roots[@]} -lt 2 ]]; then
    echo "OK: only one node sampled, nothing to compare"
    exit 0
fi

if ! oracle_stateroot_decide "${roots[@]}"; then
    echo "DIVERGE: stateRoot mismatch at height $HEIGHT across nodes"
    exit 1
fi
echo "OK: stateroot"
