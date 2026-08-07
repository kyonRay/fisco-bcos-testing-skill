#!/usr/bin/env bash
# scenario_malformed.sh — "malformed" gate scenario family: for a small set of byte-tampered /
# out-of-bounds transactions, assert the node rejects each CLEANLY rather than crashing. Reuses
# the sibling fisco-bcos-testing skill's byte-tampering recipe
# (../../../fisco-bcos-testing/references/byte-tampering.md): build a valid signed tx, decode ->
# flip exactly one field -> re-encode, inject the raw hex via curl sendTransaction, and — the
# whole point of this scenario — never take "the RPC call returned an error" at face value: a
# node that silently died while handling the tampered bytes would ALSO make the RPC call fail,
# and that is not a clean rejection, it's the bug this scenario exists to catch. Every case
# therefore pairs (a) a positive control confirming the channel works before tampering, (b) the
# rejection assertion, and (c) an oracle_crash liveness probe, all three feeding the pure
# false-green-guard function below.
#
# This file is SOURCED (by gate.sh's `for f in "$SCRIPT_DIR"/scenarios/*.sh; do source "$f";
# done` loop — see scripts/gate.sh — or standalone by tests/scenario_malformed_test.sh), so it
# must not `set -e`/`set -u` at file scope: that would change the sourcing script's own shell
# options. Registration at the bottom is guarded for the same reason. Matches scenario_ut.sh /
# scenario_dual_rpc.sh's convention exactly.
#
# Design: _mal_verdict is a pure function (no IO) — the ONLY part of this file exercised by
# tests/scenario_malformed_test.sh. scenario_malformed_run itself is live-chain-only IO (console
# + curl + oracle_crash.sh) and is NOT exercised by tests, other than its SCENARIO_DRY=1 branch
# (prints the case plan, sends nothing).
#
# GAP (documented assumption, verified only against a live chain — same honesty standard as
# scenario_dual_rpc.sh's own GAP notes):
#   - Actually producing tampered tars-encoded bytes needs a decode -> flip-field -> re-encode
#     round-trip against the real bcostars::Transaction struct. byte-tampering.md is explicit
#     that hand-editing raw tars bytes is error-prone and a small struct-aware helper is the
#     right tool for that job — the same reasoning scenario_dual_rpc.sh gives for shelling out to
#     Viem/node to do ECDSA signing rather than hand-rolling it in bash. This script does not ship
#     that helper (out of scope for this task: bash orchestration only, see brief). It requires
#     one to be supplied via TAMPER_HELPER — an executable that, given a case name, prints a
#     tampered raw tx hex on stdout — and refuses to fabricate a pass/fail by guessing bytes
#     itself when TAMPER_HELPER is missing.
#   - Native `sendTransaction`'s JSON-RPC params are assumed to be [groupID, nodeName, signedHex],
#     the same <groupID, nodeName, ...> convention scenario_dual_rpc.sh documents for
#     getBlockByNumber (see JsonRpcInterface.h) — not independently re-verified here.
#   - Node-PID discovery (for the oracle_crash probe) mirrors gate.sh's own `pgrep -f
#     "$NODE_DIR/"` convention against the cluster layout cluster_up.sh produces, overridable via
#     NODE_DIR since gate.sh does not export its own NODE_DIR to scenario scripts.
#
# Env:
#   SCENARIO_DRY=1     print the per-case plan (positive control / tamper / inject / reject
#                      assertion / oracle_crash probe / verdict) and return 0 without sending
#                      anything. This is the only path exercised by this repo's own tests.
#   TAMPER_HELPER      executable: `TAMPER_HELPER <case_name>` prints a tampered raw tx hex (no
#                      "0x" prefix assumed either way — passed through as-is) on stdout. No
#                      default is shipped (see GAP above); a real run must supply one.
#   NODE_DIR           cluster node-dir root to pgrep node PIDs under (default matches gate.sh's
#                      own CLUSTER_OUTDIR="./nodes-release-gate" layout:
#                      ./nodes-release-gate/127.0.0.1).
#   BCOS_RPC_URL       BCOS RPC endpoint (default http://127.0.0.1:20200)
#   BCOS_GROUP_ID      group id for the <groupID, nodeName, ...> param convention (default
#                      "group0")
#   BCOS_CONTRACT_NAME contract deployed by the positive control via the console (default
#                      "HelloWorld", matching scenario_dual_rpc.sh's own default)
#   CONSOLE_DIR        console.sh working directory (default console/dist, matching
#                      ci-harnesses.md)

SCENARIO_MAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Case list: generic tamper categories from byte-tampering.md's tars field map (illegal `to`,
# out-of-bounds numeric field, bad signature) — kept generic rather than tied to specific FIB
# numbers, per this repo's own "facts don't get baked in" editing invariant (CLAUDE.md): the
# per-release incident numbers live in byte-tampering.md, not duplicated here.
MAL_CASES=(
    "illegal_to:TransactionData.to (tag 6) set to an illegal/out-of-bounds address length"
    "oob_field:TransactionData.blockLimit (tag 4) set to a negative/overflowing value"
    "bad_signature:Transaction.signature (tag 3) flipped so it no longer matches Transaction.dataHash (tag 2)"
)

# ---------------------------------------------------------------------------
# Pure function — no IO. The only part of this file unit-tested by
# tests/scenario_malformed_test.sh.
# ---------------------------------------------------------------------------

# _mal_verdict <rpc_rejected> <node_alive> — return 0 (pass: clean rejection) ONLY IF
# rpc_rejected==1 AND node_alive==1. If node_alive==0 (the node crashed while handling the
# tampered bytes), return 1 (FAIL) EVEN WHEN rpc_rejected==1 — a crash disguised as a rejection is
# exactly the false-green this scenario exists to catch, not a pass.
_mal_verdict() {
    local rejected="$1"
    local alive="$2"
    [[ "$rejected" == "1" && "$alive" == "1" ]]
}

# ---------------------------------------------------------------------------
# IO helpers — live-chain-only, never called from SCENARIO_DRY=1 or from this repo's tests.
# ---------------------------------------------------------------------------

# _mal_console <cmd...> — run one console.sh command from CONSOLE_DIR and print its raw stdout.
# Same shape as scenario_dual_rpc.sh's _drpc_console, duplicated rather than sourced to keep this
# scenario from depending on that script's internal (non-interface) function name.
_mal_console() {
    local console_dir="${CONSOLE_DIR:-console/dist}"
    (cd "$console_dir" && bash console.sh "$@")
}

# _mal_positive_control <outdir> <case_name> — deploy the default contract via the console to
# confirm the RPC channel works BEFORE sending the tampered tx for this case. Prints ONLY the
# deployed contract address on stdout (unused by the caller today, kept for parity with
# scenario_dual_rpc.sh's stdout-purity convention); every progress/OK/ERROR line goes to stderr.
_mal_positive_control() {
    local outdir="$1"
    local case_name="$2"
    local log="$outdir/malformed_${case_name}.log"
    local out addr

    echo ">> scenario_malformed: [$case_name] positive control: console deploy ${BCOS_CONTRACT_NAME:-HelloWorld} (confirm channel works before tampering)" | tee -a "$log" >&2
    out="$(_mal_console deploy "${BCOS_CONTRACT_NAME:-HelloWorld}")"
    echo "$out" >>"$log"
    # Anchored on the "contract address:" label for the same reason scenario_dual_rpc.sh is: the
    # console prints the 64-hex transaction hash first, whose 40-hex prefix an unanchored grep
    # happily returns as the contract address.
    addr="$(printf '%s' "$out" | sed -E -n 's/.*contract address:[[:space:]]*(0x[0-9a-fA-F]{40}).*/\1/p' | head -n1)"
    if [[ -z "$addr" ]]; then
        echo "ERROR: scenario_malformed: [$case_name] positive control failed — could not parse a deployed contract address from console output; channel may be down" | tee -a "$log" >&2
        return 1
    fi
    echo "OK: scenario_malformed: [$case_name] positive control succeeded (deployed $addr)" | tee -a "$log" >&2
    printf '%s' "$addr"
}

# _mal_send_raw <hex> <case_name> — curl the tampered raw tx hex to native sendTransaction, print
# ONLY the raw JSON-RPC response on stdout (stdout-purity convention — caller decides
# rejected/accepted from the response text; all progress lines go to stderr).
_mal_send_raw() {
    local hex="$1"
    local case_name="$2"
    local url="${BCOS_RPC_URL:-http://127.0.0.1:20200}"
    local resp

    echo ">> scenario_malformed: [$case_name] curl sendTransaction (tampered hex, ${#hex} chars)" >&2
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"sendTransaction\",\"params\":[\"${BCOS_GROUP_ID:-group0}\",\"\",\"$hex\"],\"id\":1}" \
        "$url" 2>/dev/null)"
    printf '%s' "$resp"
}

# _mal_discover_pids — print live fisco-bcos node PIDs, one per line, discovered via pgrep against
# NODE_DIR (see header GAP note). Empty output (no lines) means none found.
_mal_discover_pids() {
    local node_dir="${NODE_DIR:-./nodes-release-gate/127.0.0.1}"
    pgrep -f "$node_dir/" 2>/dev/null || true
}

# _mal_dry — print the plan SCENARIO_DRY=1 would take, one block per tamper case, without sending
# anything. This is the only branch of this scenario exercised outside a live chain.
_mal_dry() {
    local case_entry name desc
    for case_entry in "${MAL_CASES[@]}"; do
        name="${case_entry%%:*}"
        desc="${case_entry#*:}"
        echo "DRY: scenario_malformed: case '$name' ($desc)"
        echo "DRY: scenario_malformed:   1) positive control: console deploy ${BCOS_CONTRACT_NAME:-HelloWorld}, confirm channel works"
        echo "DRY: scenario_malformed:   2) craft tampered tx via TAMPER_HELPER '$name' (byte-tampering.md recipe: decode -> flip field -> re-encode)"
        echo "DRY: scenario_malformed:   3) curl sendTransaction the tampered hex, check for a rejection response"
        echo "DRY: scenario_malformed:   4) oracle_crash --once probe: confirm node still alive"
        echo "DRY: scenario_malformed:   5) _mal_verdict <rejected> <alive>"
    done
}

# scenario_malformed_run <outdir> — for each tamper case: positive control, tamper+inject, assert
# rejection, probe liveness, feed both into _mal_verdict. Live-chain-only: needs a running BCOS
# RPC (:20200) node, a discoverable node PID, and an executable TAMPER_HELPER (see header GAP
# note). Returns 1 if any case fails its verdict, its positive control, or if pre-flight discovery
# (node PIDs, TAMPER_HELPER) comes up empty.
scenario_malformed_run() {
    local outdir="${1:-.}"

    if [[ "${SCENARIO_DRY:-0}" == 1 ]]; then
        _mal_dry
        return 0
    fi

    mkdir -p "$outdir"

    local pids=()
    mapfile -t pids < <(_mal_discover_pids)
    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "ERROR: scenario_malformed: could not discover any live fisco-bcos node PIDs under ${NODE_DIR:-./nodes-release-gate/127.0.0.1} — set NODE_DIR to the cluster's node-dir root, or bring up a chain first (see apply_profile.sh). Real-run requires a live chain; refusing to continue with no crash-oracle PIDs." >&2
        return 1
    fi

    local tamper_helper="${TAMPER_HELPER:-}"
    if [[ -z "$tamper_helper" || ! -x "$tamper_helper" ]]; then
        echo "ERROR: scenario_malformed: TAMPER_HELPER not set to an executable. byte-tampering.md's recipe requires a decode -> flip-field -> re-encode round-trip against the real tars Transaction struct, which this bash-only scenario does not build itself (see ../../../fisco-bcos-testing/references/byte-tampering.md). Set TAMPER_HELPER to a script/binary where 'TAMPER_HELPER <case_name>' prints a tampered raw tx hex on stdout." >&2
        return 1
    fi

    local rc=0 case_entry name desc
    for case_entry in "${MAL_CASES[@]}"; do
        name="${case_entry%%:*}"
        desc="${case_entry#*:}"
        echo "-- scenario_malformed: case '$name' ($desc)"

        if ! _mal_positive_control "$outdir" "$name" >/dev/null; then
            rc=1
            continue
        fi

        local hex
        hex="$("$tamper_helper" "$name")" || {
            echo "ERROR: scenario_malformed: [$name] TAMPER_HELPER failed" >&2
            rc=1
            continue
        }
        if [[ -z "$hex" ]]; then
            echo "ERROR: scenario_malformed: [$name] TAMPER_HELPER printed no hex" >&2
            rc=1
            continue
        fi

        local resp rejected=0 alive=0
        resp="$(_mal_send_raw "$hex" "$name")"
        echo "$resp" >>"$outdir/malformed_${name}.log"
        if [[ "$resp" == *'"error"'* ]]; then
            rejected=1
        fi

        if bash "$SCENARIO_MAL_DIR/../oracle_crash.sh" --once "${pids[@]}" >>"$outdir/malformed_${name}.log" 2>&1; then
            alive=1
        fi

        if _mal_verdict "$rejected" "$alive"; then
            echo "OK: scenario_malformed: case '$name' cleanly rejected, node alive"
        else
            echo "FAIL: scenario_malformed: case '$name' rejected=$rejected alive=$alive (crash-disguised-as-reject, or malformed tx was not rejected)" >&2
            rc=1
        fi
    done
    return $rc
}

# Register into gate.sh's GATE_SCENARIOS map. Guarded: when this file is sourced standalone
# (e.g. by tests/scenario_malformed_test.sh) rather than via gate.sh, gate.sh's own
# `declare -A GATE_SCENARIOS=()` has not run yet, so under `set -u` a bare assignment into
# GATE_SCENARIOS[malformed]=... would abort the sourcing script with "unbound variable". Declare
# it (idempotently — declare -A on an already-declared array is a harmless no-op, never resets an
# existing map) before the assignment so standalone sourcing never crashes. Matches
# scenario_ut.sh / scenario_dual_rpc.sh's registration guard exactly.
declare -gA GATE_SCENARIOS 2>/dev/null || true
GATE_SCENARIOS[malformed]=scenario_malformed_run
