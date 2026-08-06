#!/usr/bin/env bash
# scenario_dual_rpc.sh — "dual_rpc" gate scenario family: deploy + call a minimal contract
# through BOTH RPC surfaces FISCO-BCOS exposes (BCOS RPC :20200 via the console/tars path, Web3
# RPC :8545 via curl eth_sendRawTransaction), verify each transaction's receipt status and call
# return value, then sample stateRoot at the same height through both surfaces and feed both into
# oracle_stateroot_decide (scripts/oracle_lib.sh, Task 5) — the two RPCs share one ledger and
# account state (see ../../fisco-bcos-testing/references/rpc-paths.md), so this is the
# state-mismatch oracle's most direct use: confirm both paths report the same state after driving
# a transaction through each. rpc-paths.md also documents why the two RPCs are NOT
# interchangeable (tars-encoded tx vs Ethereum RLP) — hence one scenario, two independent tx
# flows, not one flow reused twice.
#
# This file is SOURCED (by gate.sh's `for f in "$SCRIPT_DIR"/scenarios/*.sh; do source "$f";
# done` loop — see scripts/gate.sh — or standalone by tests/scenario_dual_rpc_test.sh), so it
# must not `set -e`/`set -u` at file scope: that would change the sourcing script's own shell
# options. Registration at the bottom is guarded for the same reason (see there). This matches
# scenario_ut.sh's convention exactly.
#
# Design: the "did the tx do what we expected" comparisons are pure functions
# (_drpc_assert_receipt, _drpc_assert_return, both below) — the ONLY part exercised by this
# repo's own tests, because they take their inputs as plain arguments and do no IO.
# scenario_dual_rpc_run itself is live-chain-only IO (console + curl) and is NOT exercised by
# tests/scenario_dual_rpc_test.sh; SCENARIO_DRY=1 makes it print the steps it would take instead
# of sending anything, which IS exercised.
#
# Both RPC paths deploy the SAME trivial "always returns 42" EVM bytecode — no Solidity compile,
# no ABI encoding needed, since the deployed contract ignores calldata entirely:
#   init code:    600a600c600039600a6000f3
#   runtime code: 602a60005260206000f3
#     PUSH1 0x2a; PUSH1 0x00; MSTORE; PUSH1 0x20; PUSH1 0x00; RETURN
# Any call to the deployed contract returns 0x...002a (42) regardless of calldata. This keeps the
# scenario a minimal deploy+call ("cleanliness over completeness" — this whole path is live-only
# and unverifiable in a checkout with no running chain) while still giving both RPC paths a
# directly comparable expected return value.
#
# Env:
#   SCENARIO_DRY=1        print the steps that would run against each RPC and return 0 without
#                          executing anything. This is the only path exercised by this repo's own
#                          tests (there is no live chain in this environment).
#   BCOS_RPC_URL           BCOS RPC endpoint (default http://127.0.0.1:20200)
#   BCOS_GROUP_ID          group id for BCOS RPC's <groupID, nodeName, ...> JSON-RPC param
#                          convention (default "group0", the AIR-mode default — see
#                          JsonRpcInterface.h and the console's own "[group0]: /apps>" prompt)
#   WEB3_RPC_URL           Web3 RPC endpoint (default http://127.0.0.1:8545)
#   WEB3_PRIVATE_KEY       hex private key of a FUNDED account to sign the Web3-side deploy+call
#                          with. No default — a real run must supply one; see rpc-paths.md's
#                          "Enable the Web3 path first" for how to fund one via the console's
#                          addBalance (needs feature_balance on).
#
# GAP (documented assumption, verified only against a live chain — same honesty standard as
# gate.sh's own real-run section): the BCOS-RPC deploy/call flow below drives the console via
# `bash console.sh <cmd>` from CWD console/dist (matching ci-harnesses.md's own convention:
# "in console/dist, with certs copied in") and parses its text output with grep/sed. Console
# output formatting is not part of this skill's own interface contract, so that parsing is a
# best-effort assumption, not a verified contract.

SCENARIO_DRPC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# oracle_lib.sh is a library file meant to be sourced by a script that already sets
# `set -euo pipefail` itself (its own header says so) — same pattern oracle_stateroot.sh and
# gate.sh already use for profile_lib.sh/oracle_lib.sh. Both of this file's own sourcing contexts
# (gate.sh, tests/scenario_dual_rpc_test.sh) already set those options before sourcing us, so
# this is a no-op on shell state there, not a new side effect.
source "$SCENARIO_DRPC_DIR/../oracle_lib.sh"

# ---------------------------------------------------------------------------
# Pure comparison functions — no IO. The only part of this file unit-tested by
# tests/scenario_dual_rpc_test.sh.
# ---------------------------------------------------------------------------

# _drpc_assert_receipt <actual_status> <expected_status> — return 0 when a transaction's observed
# receipt status equals what a legal deploy/call was expected to report, else return 1. The two
# RPCs use different success-status conventions (BCOS RPC: "0"; Web3/Ethereum: "0x1") — this
# function doesn't care, the caller passes whichever "expected" value matches the RPC it's
# checking.
_drpc_assert_receipt() {
    local actual="$1" expected="$2"
    [[ "$actual" == "$expected" ]]
}

# _drpc_assert_return <actual> <expected> — return 0 when a contract call's observed return value
# equals what was expected, else return 1.
_drpc_assert_return() {
    local actual="$1" expected="$2"
    [[ "$actual" == "$expected" ]]
}

# ---------------------------------------------------------------------------
# IO helpers — live-chain-only, never called from SCENARIO_DRY=1 or from this repo's tests.
# ---------------------------------------------------------------------------

# _drpc_rpc_call <url> <method> <json_params_array> — one JSON-RPC POST, print the raw response.
# Shared shape for both RPC surfaces (they differ only in method names / param conventions, not
# transport — both are plain HTTP JSON-RPC, per rpc-paths.md).
_drpc_rpc_call() {
    local url="$1" method="$2" params="$3"
    curl -sS -m 10 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" \
        "$url" 2>/dev/null
}

# _drpc_json_hexfield <json> <field> — pull a "field":"0x..." value out of a JSON-RPC response
# without a jq dependency. Same sed idiom oracle_stateroot.sh already uses for "stateRoot".
_drpc_json_hexfield() {
    printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\(0x[0-9a-fA-F]*\\)\".*/\\1/p"
}

# _drpc_bcos_state_root <height> — stateRoot at <height> via BCOS RPC's getBlockByNumber, which
# (unlike Web3's eth_getBlockByNumber) takes <groupID, nodeName, blockNumber, includeTx> — see
# JsonRpcInterface.h. nodeName "" asks for the default/any node.
_drpc_bcos_state_root() {
    local height="$1" resp
    resp="$(_drpc_rpc_call "${BCOS_RPC_URL:-http://127.0.0.1:20200}" getBlockByNumber \
        "[\"${BCOS_GROUP_ID:-group0}\",\"\",$height,false]")"
    _drpc_json_hexfield "$resp" stateRoot
}

# _drpc_web3_state_root <height> — stateRoot at <height> via Web3 RPC's eth_getBlockByNumber.
# Duplicates oracle_stateroot.sh's private rpc_state_root rather than sourcing it, to keep this
# scenario from depending on that script's internal (non-interface) function name — same
# reasoning gate.sh gives for its own rpc_current_height duplicate.
_drpc_web3_state_root() {
    local height="$1" hex resp
    hex="$(printf '0x%x' "$height")"
    resp="$(_drpc_rpc_call "${WEB3_RPC_URL:-http://127.0.0.1:8545}" eth_getBlockByNumber "[\"$hex\",false]")"
    _drpc_json_hexfield "$resp" stateRoot
}

# _drpc_console <cmd...> — run one console.sh command from CONSOLE_DIR (default console/dist,
# matching ci-harnesses.md) and print its raw stdout.
_drpc_console() {
    local console_dir="${CONSOLE_DIR:-console/dist}"
    ( cd "$console_dir" && bash console.sh "$@" )
}

# _drpc_bcos_deploy_and_call <outdir> — BCOS RPC path: deploy the demo contract via the console,
# call it, verify receipt status + return value with the pure functions above. Prints the block
# height its call transaction landed at (for the stateRoot sample), on stdout as the last line.
_drpc_bcos_deploy_and_call() {
    local outdir="$1" log="$outdir/dual_rpc_bcos.log"
    local deploy_out addr status height got

    echo ">> scenario_dual_rpc: BCOS RPC (console, :${BCOS_RPC_URL:-http://127.0.0.1:20200}): deploy ${BCOS_CONTRACT_NAME:-HelloWorld}" | tee -a "$log"
    deploy_out="$(_drpc_console deploy "${BCOS_CONTRACT_NAME:-HelloWorld}")"
    echo "$deploy_out" >> "$log"
    addr="$(printf '%s' "$deploy_out" | grep -oE '0x[0-9a-fA-F]{40}' | head -n1)"
    [[ -n "$addr" ]] || { echo "ERROR: scenario_dual_rpc: could not parse deployed contract address from console output" >&2; return 1; }

    echo ">> scenario_dual_rpc: BCOS RPC: call set(42) on $addr" | tee -a "$log"
    local call_out
    call_out="$(_drpc_console call "${BCOS_CONTRACT_NAME:-HelloWorld}" "$addr" set 42)"
    echo "$call_out" >> "$log"
    status="$(printf '%s' "$call_out" | sed -n 's/.*status[^0-9x]*\(0x[0-9a-fA-F]\+\|[0-9]\+\).*/\1/p' | head -n1)"
    [[ -n "$status" ]] || { echo "ERROR: scenario_dual_rpc: could not parse a status field from console call output" | tee -a "$log" >&2; return 1; }
    status="$((status))"
    if ! _drpc_assert_receipt "$status" 0; then
        echo "FAIL: scenario_dual_rpc: BCOS RPC set() receipt status=$status, expected 0" | tee -a "$log" >&2
        return 1
    fi

    echo ">> scenario_dual_rpc: BCOS RPC: call get() on $addr" | tee -a "$log"
    got="$(_drpc_console call "${BCOS_CONTRACT_NAME:-HelloWorld}" "$addr" get | tail -n1 | tr -d '[:space:]')"
    if ! _drpc_assert_return "$got" "42"; then
        echo "FAIL: scenario_dual_rpc: BCOS RPC get() returned '$got', expected '42'" | tee -a "$log" >&2
        return 1
    fi
    echo "OK: scenario_dual_rpc: BCOS RPC path (status=0 return=42)" | tee -a "$log"

    height="$(printf '%s' "$call_out" | sed -n 's/.*block number[^0-9]*\([0-9]\+\).*/\1/p' | head -n1)"
    echo "$height"
}

# _drpc_web3_deploy_and_call <outdir> — Web3 RPC path: sign+submit the "return 42" bytecode via
# curl eth_sendRawTransaction, verify receipt status, then eth_call the deployed address and
# verify the return value with the pure functions above. Prints the block height its deploy
# transaction landed at (for the stateRoot sample), on stdout as the last line.
#
# Signing needs a real secp256k1 signature + RLP encoding — genuinely not something to hand-roll
# in bash. This shells out to Viem (already the sibling skill's own recommended tool for building
# Web3-path transactions, see rpc-paths.md) purely to SIGN; curl still does the actual
# eth_sendRawTransaction submission per this scenario's own design (brief Step 3). Requires
# `node` + `npm i viem` available on PATH — a real run must have both.
_drpc_web3_deploy_and_call() {
    local outdir="$1" log="$outdir/dual_rpc_web3.log"
    local url="${WEB3_RPC_URL:-http://127.0.0.1:8545}"
    local initcode="600a600c600039600a6000f3602a60005260206000f3"
    local nonce chain_id gas_price raw resp tx_hash receipt status addr call_resp got height

    [[ -n "${WEB3_PRIVATE_KEY:-}" ]] || { echo "ERROR: scenario_dual_rpc: WEB3_PRIVATE_KEY not set (need a funded account's key — see rpc-paths.md)" >&2; return 1; }

    nonce="$(_drpc_json_hexfield "$(_drpc_rpc_call "$url" eth_getTransactionCount "[\"$(_drpc_web3_address)\",\"latest\"]")" result 2>/dev/null || true)"
    chain_id="$(_drpc_json_hexfield "$(_drpc_rpc_call "$url" eth_chainId "[]")" result)"
    gas_price="$(_drpc_json_hexfield "$(_drpc_rpc_call "$url" eth_gasPrice "[]")" result)"

    echo ">> scenario_dual_rpc: Web3 RPC ($url): sign+deploy 'return 42' bytecode" | tee -a "$log"
    raw="$(_drpc_web3_sign "" "0x$initcode" "$nonce" "$chain_id" "$gas_price")"
    resp="$(_drpc_rpc_call "$url" eth_sendRawTransaction "[\"$raw\"]")"
    tx_hash="$(_drpc_json_hexfield "$resp" result)"
    [[ -n "$tx_hash" ]] || { echo "ERROR: scenario_dual_rpc: eth_sendRawTransaction did not return a tx hash: $resp" | tee -a "$log" >&2; return 1; }

    receipt="$(_drpc_rpc_call "$url" eth_getTransactionReceipt "[\"$tx_hash\"]")"
    status="$(_drpc_json_hexfield "$receipt" status)"
    [[ -n "$status" ]] || { echo "ERROR: scenario_dual_rpc: could not parse status from Web3 receipt: $receipt" | tee -a "$log" >&2; return 1; }
    status="$((status))"
    if ! _drpc_assert_receipt "$status" 1; then
        echo "FAIL: scenario_dual_rpc: Web3 RPC deploy receipt status=$status, expected 1" | tee -a "$log" >&2
        return 1
    fi
    addr="$(_drpc_json_hexfield "$receipt" contractAddress)"
    height="$(_drpc_json_hexfield "$receipt" blockNumber)"
    [[ -n "$height" ]] || { echo "ERROR: scenario_dual_rpc: could not parse blockNumber from Web3 receipt: $receipt" | tee -a "$log" >&2; return 1; }
    height="$((height))"

    echo ">> scenario_dual_rpc: Web3 RPC: eth_call $addr" | tee -a "$log"
    call_resp="$(_drpc_rpc_call "$url" eth_call "[{\"to\":\"$addr\",\"data\":\"0x\"},\"latest\"]")"
    got="$(_drpc_json_hexfield "$call_resp" result | sed -E 's/^0x0*/0x/')"
    if ! _drpc_assert_return "$got" "0x2a"; then
        echo "FAIL: scenario_dual_rpc: Web3 RPC eth_call returned '$got', expected '0x2a'" | tee -a "$log" >&2
        return 1
    fi
    echo "OK: scenario_dual_rpc: Web3 RPC path (status=1 return=0x2a)" | tee -a "$log"
    echo "$height"
}

# _drpc_web3_address — derive the funded account's address from WEB3_PRIVATE_KEY via Viem.
_drpc_web3_address() {
    node -e '
        import("viem/accounts").then(({ privateKeyToAccount }) => {
            console.log(privateKeyToAccount(process.env.WEB3_PRIVATE_KEY).address);
        });
    ' 2>/dev/null
}

# _drpc_web3_sign <to|""> <data> <nonce_hex> <chain_id_hex> <gas_price_hex> — print a signed raw
# transaction hex ready for eth_sendRawTransaction. <to>="" means contract deployment.
_drpc_web3_sign() {
    local to="$1" data="$2" nonce="$3" chain_id="$4" gas_price="$5"
    WEB3_TO="$to" WEB3_DATA="$data" WEB3_NONCE="$nonce" WEB3_CHAIN_ID="$chain_id" WEB3_GAS_PRICE="$gas_price" \
        node -e '
        import("viem/accounts").then(async ({ privateKeyToAccount }) => {
            const account = privateKeyToAccount(process.env.WEB3_PRIVATE_KEY);
            const tx = {
                to: process.env.WEB3_TO || undefined,
                data: process.env.WEB3_DATA,
                nonce: Number(process.env.WEB3_NONCE),
                chainId: Number(process.env.WEB3_CHAIN_ID),
                gasPrice: BigInt(process.env.WEB3_GAS_PRICE),
                gas: 500000n,
            };
            console.log(await account.signTransaction(tx));
        });
    ' 2>/dev/null
}

# _drpc_dry — print the steps SCENARIO_DRY=1 would take, one per RPC path, without sending
# anything. This is the only branch of this scenario exercised outside a live chain.
_drpc_dry() {
    echo "DRY: scenario_dual_rpc: BCOS RPC (${BCOS_RPC_URL:-http://127.0.0.1:20200}): console deploy ${BCOS_CONTRACT_NAME:-HelloWorld}"
    echo "DRY: scenario_dual_rpc: BCOS RPC: console call set(42), verify receipt status via _drpc_assert_receipt"
    echo "DRY: scenario_dual_rpc: BCOS RPC: console call get(), verify return value via _drpc_assert_return"
    echo "DRY: scenario_dual_rpc: Web3 RPC (${WEB3_RPC_URL:-http://127.0.0.1:8545}): sign+curl eth_sendRawTransaction deploy 'return 42' bytecode"
    echo "DRY: scenario_dual_rpc: Web3 RPC: curl eth_getTransactionReceipt, verify status via _drpc_assert_receipt"
    echo "DRY: scenario_dual_rpc: Web3 RPC: curl eth_call, verify return value via _drpc_assert_return"
    echo "DRY: scenario_dual_rpc: sample stateRoot from both RPC surfaces, compare via oracle_stateroot_decide"
}

# scenario_dual_rpc_run <outdir> — run both RPC paths, verify each, then cross-check stateRoot.
# Live-chain-only: needs a running BCOS RPC (:20200) and Web3 RPC (:8545) node, and (for the Web3
# path) a funded WEB3_PRIVATE_KEY. Returns 1 on any assertion failure or stateRoot divergence.
scenario_dual_rpc_run() {
    local outdir="${1:-.}"

    if [[ "${SCENARIO_DRY:-0}" == 1 ]]; then
        _drpc_dry
        return 0
    fi

    mkdir -p "$outdir"

    local bcos_height web3_height
    bcos_height="$(_drpc_bcos_deploy_and_call "$outdir")" || return 1
    web3_height="$(_drpc_web3_deploy_and_call "$outdir")" || return 1

    # Cross-check: both RPCs share one ledger/account state (rpc-paths.md) — after driving a tx
    # through each, the stateRoot each surface reports at the OTHER surface's settle height
    # should agree with what that surface itself reports, i.e. neither surface's own view of the
    # shared state has drifted. Compare at the later of the two heights, where both txs are final.
    local height=$(( bcos_height > web3_height ? bcos_height : web3_height ))
    echo ">> scenario_dual_rpc: cross-checking stateRoot @ $height via both RPC surfaces"
    local root_bcos root_web3
    root_bcos="$(_drpc_bcos_state_root "$height")"
    root_web3="$(_drpc_web3_state_root "$height")"
    if [[ -z "$root_bcos" || -z "$root_web3" ]]; then
        echo "ERROR: scenario_dual_rpc: could not read stateRoot @ $height from one or both RPC surfaces (bcos='$root_bcos' web3='$root_web3')" >&2
        return 1
    fi
    if ! oracle_stateroot_decide "$root_bcos" "$root_web3"; then
        echo "DIVERGE: scenario_dual_rpc: stateRoot mismatch @ $height — BCOS RPC=$root_bcos Web3 RPC=$root_web3" >&2
        return 1
    fi
    echo "OK: scenario_dual_rpc: stateRoot agrees across both RPC surfaces @ $height ($root_bcos)"
}

# Register into gate.sh's GATE_SCENARIOS map. Guarded: when this file is sourced standalone
# (e.g. by tests/scenario_dual_rpc_test.sh) rather than via gate.sh, gate.sh's own
# `declare -A GATE_SCENARIOS=()` has not run yet, so under `set -u` a bare assignment into
# GATE_SCENARIOS[dual_rpc]=... would abort the sourcing script with "unbound variable". Declare
# it (idempotently — declare -A on an already-declared array is a harmless no-op, never resets an
# existing map) before the assignment so standalone sourcing never crashes. Matches
# scenario_ut.sh's registration guard exactly.
declare -gA GATE_SCENARIOS 2>/dev/null || true
GATE_SCENARIOS[dual_rpc]=scenario_dual_rpc_run
