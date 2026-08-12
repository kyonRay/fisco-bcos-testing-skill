#!/usr/bin/env bash
# tamper-helper.sh — the executable scenario_malformed.sh's TAMPER_HELPER env var points at.
# `TAMPER_HELPER <case_name>` must print one line of tampered raw tx hex on stdout and nothing
# else. Before exec'ing java, this wrapper best-effort queries the live chain's current block
# height and passes an in-window base blockLimit to TamperFuzz via TAMPER_BLOCK_LIMIT: a base
# blockLimit outside the chain's valid window (roughly (currentBlock, currentBlock+~1000)) makes
# the node reject at the blockLimit gate before it ever reaches signature/`to` validation, which
# turned illegal_to into a false-green in a live run (see TamperFuzz.java's baseBlockLimit()
# comment). All diagnostics go to stderr; stdout stays pure hex.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Beside this script first: that IS the installed layout (install.sh puts both in
# libexec/fbt/tools/). build/libs/ is the local gradle dev tree, and TAMPER_FUZZ_JAR overrides both.
# Probing only build/libs/ left an installed engine with no jar at all, and the malformed scenario
# then failed as though the CHAIN had misbehaved rather than the machine being incomplete.
JAR="${TAMPER_FUZZ_JAR:-}"
if [[ -z "$JAR" ]]; then
    if [[ -f "$SCRIPT_DIR/tamper-fuzz-all.jar" ]]; then
        JAR="$SCRIPT_DIR/tamper-fuzz-all.jar"
    else
        JAR="$SCRIPT_DIR/build/libs/tamper-fuzz-all.jar"
    fi
fi

# Respect an explicit caller override; otherwise probe the live chain. On any failure (offline,
# RPC down, unparseable response) leave TAMPER_BLOCK_LIMIT unset so TamperFuzz falls back to its
# own offline default — this keeps `--selfcheck` and other offline uses working with no chain.
if [[ -z "${TAMPER_BLOCK_LIMIT:-}" ]]; then
    url="${BCOS_RPC_URL:-http://127.0.0.1:20200}"
    group="${BCOS_GROUP_ID:-group0}"
    blk="$(curl -sS -m 5 -X POST "$url" -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"getBlockNumber","params":["'"$group"'",""],"id":1}' 2>/dev/null \
        | grep -oE '"result":[0-9]+' | grep -oE '[0-9]+' || true)"
    if [[ "$blk" =~ ^[0-9]+$ ]]; then
        export TAMPER_BLOCK_LIMIT=$((blk + 500))
        echo ">> tamper-helper: live chain height=$blk, TAMPER_BLOCK_LIMIT=$TAMPER_BLOCK_LIMIT" >&2
    else
        echo ">> tamper-helper: could not query live chain height from $url (offline or RPC down);" \
            "using TamperFuzz's offline default blockLimit" >&2
    fi
fi

exec java -jar "$JAR" "$@"
