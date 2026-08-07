#!/usr/bin/env bash
# fuzz_bcos.sh — open-seed BCOS-RPC fuzz driver (exploration layer, Step 6). Standalone: NOT
# sourced by gate.sh and NOT registered into GATE_SCENARIOS — open-ended fuzzing stays outside the
# deterministic gate sweep by design (a deliberate architecture decision; do not wire this in).
#
# THE JUDGMENT IS INVERTED vs scripts/scenarios/scenario_malformed.sh. That scenario asks "did the
# node reject this ONE tampered tx cleanly?" — rejection = pass, scored per input. This driver
# fires MANY random mutants per batch and does NOT score per input: rejection is the boring,
# expected, healthy path (do not fail on rejections, just tally them). What this driver hunts is
# inputs that make the node crash / halt consensus / diverge state — so it injects a whole batch,
# then runs the oracles ONCE per batch to ask "did the node survive this batch as a whole". Only on
# an oracle trip does it care WHICH input did it, and the only way back to that input is to replay
# (seed, idx) — see FuzzGenerator's DETERMINISM CONTRACT
# (tools/tamper-fuzz/src/main/java/fisco/tamperfuzz/FuzzGenerator.java): same (count, seed,
# strategy) always regenerates byte-identical mutants, so bisection (below) can regenerate any
# sub-range of a batch and get back the exact same bytes that were in the original run.
#
# Usage:
#   fuzz_bcos.sh [-o outdir] [--dry-run] [-h]
#     -o  local output dir for this driver's own logs/failures.jsonl   (default
#         ./nodes-release-gate-fuzz — separate from NODE_DIR, the cluster this driver attaches to)
#     --dry-run  print the resolved run plan (base seed, budget mode, batch size, strategy, jar
#                path) and exit 0 — no live chain touched. Safe anywhere, no chain required.
#     -h  print this help and exit
#
# Env:
#   NODE_DIR             cluster node-dir root to pgrep node PIDs under, same convention as
#                         scenario_malformed.sh / gate.sh (default ./nodes-release-gate/127.0.0.1)
#   BCOS_RPC_URL          native BCOS RPC endpoint sendTransaction is injected against (default
#                         http://127.0.0.1:20200)
#   BCOS_GROUP_ID         group id for the <groupID, nodeName, hex> sendTransaction param
#                         convention (default group0), same as scenario_malformed.sh
#   RG_FUZZ_WEB3_URL      Web3 RPC endpoint the liveness/stateroot oracles poll (default
#                         http://127.0.0.1:8545 — the AIR default web3_rpc.listen_port)
#   RG_FUZZ_STATEROOT_URLS  comma-separated EXTRA node Web3 RPC URLs to compare stateRoot against
#                         RG_FUZZ_WEB3_URL. GAP: this driver has no profile/cluster-layout wiring
#                         to auto-discover other nodes' ports (see run_case.sh / gate.sh's own
#                         identical documented gap for oracle_stateroot.sh) — unset (the default)
#                         means the stateroot oracle is SKIPPED and only crash+liveness run; set
#                         this to enable it once you know the other nodes' RPC URLs.
#   RG_FUZZ_ITERS         batches to run (default 20). Ignored when RG_FUZZ_SEC is set and > 0.
#   RG_FUZZ_SEC           wall-clock budget in seconds; if set and > 0, takes PRECEDENCE over
#                         RG_FUZZ_ITERS — an explicit time box is honored regardless of how many
#                         batches happen to fit in it. Unset/0 (the default) means RG_FUZZ_ITERS
#                         governs instead. See _fuzz_plan_mode.
#   RG_FUZZ_SEED          base seed (default 42, a FIXED constant — never time/random: a whole
#                         run must be reproducible end to end). Per-batch seed = base + batch_idx
#                         (_fuzz_batch_seed).
#   RG_FUZZ_BATCH         mutants generated per batch (default 100)
#   RG_FUZZ_STRATEGY      struct | bytes | both, passed straight to the java `fuzz` call (default
#                         both)
#   RG_FUZZ_CONTINUE      if =1, keep running batches after an oracle trip instead of stopping.
#                         Default: stop after the first confirmed trip — a crash/halt is a finding,
#                         hammering a downed node further does not find more of it.
#   RG_FUZZ_RESTART_CMD   shell command (run via `bash -c`) that restores the cluster to health —
#                         e.g. the node cluster's own start_all.sh. PRECEDENCE / gating (see
#                         _fuzz_should_bisect and the Bisection section below):
#                           - unset AND the batch trip was a genuine crash (pids actually gone):
#                             bisection is SKIPPED entirely — re-injecting into a dead node cannot
#                             isolate anything, so the driver does not pretend to. The whole
#                             batch's seed range is recorded to failures.jsonl instead.
#                           - unset AND the trip was liveness-only (pids still alive, just
#                             stalled): bisection proceeds as before, no restart attempted (the
#                             node is still probeable).
#                           - set: used before EVERY bisection re-injection probe, regardless of
#                             trip type (crash or halt) — restart, re-discover PIDs, re-confirm a
#                             clean baseline, THEN inject the half being tested. If the restore
#                             does not come back healthy, bisection ABORTS immediately (does not
#                             loop against a cluster it cannot confirm is healthy). Also run once
#                             more (best-effort) after the run stops on a confirmed trip, so the
#                             box isn't left with a dead chain — see _fuzz_run's end-of-run step.
#   RG_FUZZ_PROFILE       profile path recorded into a distilled scenarios/*.case's `profile =`
#                         field (default profiles/production-enterprise.profile — override to
#                         whatever profile the live chain you attached to actually is)
#   FUZZ_JAR              path to tamper-fuzz-all.jar (default
#                         $SCRIPT_DIR/../tools/tamper-fuzz/build/libs/tamper-fuzz-all.jar)
#   JAVA_BIN              java executable (default `java` on PATH)
#
# Oracle wiring: crash (scripts/oracle_crash.sh --once) and liveness (scripts/oracle_liveness.sh)
# always run, once per batch. stateroot (scripts/oracle_stateroot.sh) runs only when
# RG_FUZZ_STATEROOT_URLS is set — see that env var's GAP note above. This mirrors the same honesty
# standard scenario_malformed.sh and run_case.sh's own documented GAPs follow: an oracle that
# cannot be meaningfully wired with the information this script has is skipped and SAID so, not
# silently assumed clean.
#
# Bisection (single-input-causality assumption): when a batch trips an oracle, this driver does
# NOT assume every mutant in the batch is guilty — it binary-searches the batch's idx range
# [0, RG_FUZZ_BATCH-1], regenerating and reinjecting one half at a time (via the deterministic
# `fuzz` regeneration property above) and rechecking crash+liveness, until it isolates a single
# idx or gives up. This assumes ONE input in the batch caused the trip.
#
# CRASH vs HALT matters for whether that assumption is even testable: if the trip was a genuine
# crash (node process actually died), re-injecting ANY half against the now-dead RPC endpoint
# trips the oracle regardless of which input was the culprit — bisection against a dead node
# cannot distinguish "this half is guilty" from "the node is just still dead from before". See
# RG_FUZZ_RESTART_CMD above: without it, a crash trip skips bisection entirely rather than
# producing a misleading "cumulative-state" verdict; with it, every probe restarts+reconfirms
# health first, so the assumption is actually being tested. Only once real per-probe restarts have
# ruled out single-input causality (neither half reproduces AFTER a confirmed-healthy restart)
# does this driver conclude "cumulative state" and record the WHOLE unresolved range rather than
# looping forever or silently guessing a wrong culprit. See _fuzz_bisect / _fuzz_should_bisect.
#
# On a confirmed trip this driver: (1) always appends one row to <outdir>/failures.jsonl via
# failures_lib.sh's failures_append (the still-open defect record); (2) IF bisection isolated a
# single idx, ALSO writes a scenarios/<name>.case fixture with expect_oracle=reject — this records
# the TARGET, post-fix behavior per scenarios/README.md's flywheel philosophy, not a claim that
# the bug is already fixed; replaying it via run_case.sh will legitimately report CASE:FAIL until
# the underlying defect actually gets fixed, at which point it starts passing and becomes a real
# regression guard. (2) does NOT happen when bisection was skipped (crash + no RG_FUZZ_RESTART_CMD)
# or left an unresolved range (no single reproducing input to pin down yet) — only (1) does then.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "fuzz_bcos.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_DIR="${NODE_DIR:-./nodes-release-gate/127.0.0.1}"
BCOS_RPC_URL="${BCOS_RPC_URL:-http://127.0.0.1:20200}"
BCOS_GROUP_ID="${BCOS_GROUP_ID:-group0}"
RG_FUZZ_WEB3_URL="${RG_FUZZ_WEB3_URL:-http://127.0.0.1:8545}"
FUZZ_JAR="${FUZZ_JAR:-${TAMPER_FUZZ_JAR:-$SCRIPT_DIR/../tools/tamper-fuzz/build/libs/tamper-fuzz-all.jar}}"
JAVA_BIN="${JAVA_BIN:-java}"

# ---------------------------------------------------------------------------
# Pure functions — no IO. Exercised directly by tests/fuzz_bcos_test.sh via
# `source scripts/fuzz_bcos.sh` (safe: see the execution guard at the bottom, same convention as
# scripts/oracle_liveness.sh's rpc_has_pending_parse split).
# ---------------------------------------------------------------------------

# _fuzz_batch_seed <base_seed> <batch_idx> — deterministic per-batch seed: base + batch_idx. A
# whole run is reproducible end to end from (base_seed, iters/sec budget, batch size, strategy)
# alone.
_fuzz_batch_seed() {
    local base="$1" batch_idx="$2"
    echo $(( base + batch_idx ))
}

# _fuzz_plan_mode <iters> <sec> — RG_FUZZ_ITERS / RG_FUZZ_SEC precedence, decided once, pure.
# Prints "sec <N>" when sec is set and > 0 (wall-clock budget governs), else "iters <N>".
_fuzz_plan_mode() {
    local iters="$1" sec="$2"
    if [[ -n "$sec" && "$sec" -gt 0 ]]; then
        echo "sec $sec"
    else
        echo "iters $iters"
    fi
}

# _fuzz_classify_response <json_response> — pure parse of one sendTransaction JSON-RPC response:
# "rejected" if it carries a JSON-RPC "error" member (same substring convention
# scenario_malformed.sh's own rejection check uses), "accepted" if it looks like a normal result,
# "unknown" for an empty/unparseable response (a curl failure or timeout) — deliberately NOT
# folded into "accepted", since silently treating "we got nothing back" as "the node accepted it"
# would mask exactly the kind of failure this driver exists to catch.
_fuzz_classify_response() {
    local resp="$1"
    if [[ -z "$resp" ]]; then
        echo "unknown"
    elif [[ "$resp" == *'"error"'* ]]; then
        echo "rejected"
    elif [[ "$resp" == *'"result"'* ]]; then
        echo "accepted"
    else
        echo "unknown"
    fi
}

# _fuzz_tally <classification...> — pure count of accepted/rejected/unknown classifications.
# Prints "accepted=X rejected=Y unknown=Z". Not a verdict — see header: rejections are the
# healthy, expected path here, this is logging only.
_fuzz_tally() {
    local accepted=0 rejected=0 unknown=0 c
    for c in "$@"; do
        case "$c" in
            accepted) accepted=$((accepted + 1)) ;;
            rejected) rejected=$((rejected + 1)) ;;
            *) unknown=$((unknown + 1)) ;;
        esac
    done
    echo "accepted=$accepted rejected=$rejected unknown=$unknown"
}

# _fuzz_bisect_done <lo> <hi> — true (0) once the range has narrowed to a single idx.
_fuzz_bisect_done() {
    local lo="$1" hi="$2"
    [[ "$lo" == "$hi" ]]
}

# _fuzz_bisect_lower_half / _fuzz_bisect_upper_half <lo> <hi> — split [lo,hi] into two halves at
# the same midpoint (mid = lo + (hi-lo)/2, integer division), covering the whole range with no gap
# and no overlap. Each prints "<lo> <hi>" for its half. Pure index math only — deciding which half
# actually reproduces a trip requires live re-injection + an oracle recheck, done by
# _fuzz_reinject_range_and_check / _fuzz_bisect below, not here.
_fuzz_bisect_lower_half() {
    local lo="$1" hi="$2"
    local mid=$(( lo + (hi - lo) / 2 ))
    echo "$lo $mid"
}
_fuzz_bisect_upper_half() {
    local lo="$1" hi="$2"
    local mid=$(( lo + (hi - lo) / 2 ))
    echo "$(( mid + 1 )) $hi"
}

# _fuzz_case_filename <seed> <idx> — single source of truth for a distilled case's filename, so
# the code that writes it and anything that later needs to find it agree.
_fuzz_case_filename() {
    local seed="$1" idx="$2"
    echo "fuzz_seed${seed}_idx${idx}.case"
}

# _fuzz_should_bisect <restart_cmd_set:0|1> <crash_tripped:0|1> — pure gating decision (see
# RG_FUZZ_RESTART_CMD in the header): should the driver attempt bisection at all after a batch
# trip? False (1) ONLY for the one case where bisection cannot mean anything — a genuine crash
# (pids actually gone) with no restart command configured to bring the cluster back before each
# probe. Every other combination proceeds: a pure liveness halt still has a probeable (alive)
# node even with no restart command, and a crash WITH a restart command configured can be
# meaningfully re-probed after each restart.
_fuzz_should_bisect() {
    local restart_cmd_set="$1" crash_tripped="$2"
    if [[ "$crash_tripped" == 1 && "$restart_cmd_set" != 1 ]]; then
        return 1
    fi
    return 0
}

# _fuzz_print_dry_plan <base_seed> <iters> <sec> <batch> <strategy> — pure formatting of the
# resolved run plan for --dry-run. No IO.
_fuzz_print_dry_plan() {
    local base_seed="$1" iters="$2" sec="$3" batch="$4" strategy="$5"
    local mode value
    read -r mode value < <(_fuzz_plan_mode "$iters" "$sec")
    echo "DRY: fuzz_bcos: base_seed=$base_seed strategy=$strategy batch_size=$batch"
    if [[ "$mode" == "sec" ]]; then
        echo "DRY: fuzz_bcos: budget: wall-clock, ${value}s (RG_FUZZ_SEC takes precedence over RG_FUZZ_ITERS)"
    else
        echo "DRY: fuzz_bcos: budget: iteration count, $value batches (RG_FUZZ_ITERS)"
    fi
    echo "DRY: fuzz_bcos: batch 0 seed = $(_fuzz_batch_seed "$base_seed" 0)"
    echo "DRY: fuzz_bcos: batch 1 seed = $(_fuzz_batch_seed "$base_seed" 1)"
    echo "DRY: fuzz_bcos: plan: preflight (PIDs + BCOS RPC + baseline oracle) -> per-batch [generate -> inject -> tally -> oracle check] -> on trip: bisect -> distill .case + failures.jsonl -> stop unless RG_FUZZ_CONTINUE=1"
}

# ---------------------------------------------------------------------------
# IO helpers — live-chain-only. NOT exercised by tests/fuzz_bcos_test.sh, only defined by sourcing
# it (function definitions are side-effect-free) — see the execution guard at the bottom.
# ---------------------------------------------------------------------------

_fuzz_discover_pids() {
    pgrep -f "${NODE_DIR}/" 2>/dev/null || true
}

_fuzz_inject_and_classify() {
    local hex="$1" resp
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"sendTransaction\",\"params\":[\"${BCOS_GROUP_ID}\",\"\",\"$hex\"],\"id\":1}" \
        "$BCOS_RPC_URL" 2>/dev/null)" || resp=""
    _fuzz_classify_response "$resp"
}

_fuzz_rpc_height() {
    local resp hex
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$RG_FUZZ_WEB3_URL" 2>/dev/null)" || { echo ""; return; }
    hex="$(printf '%s' "$resp" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    [[ -z "$hex" ]] && { echo ""; return; }
    printf '%d\n' "$hex"
}

# _fuzz_oracle_check_once <label> — one bounded pass of crash + liveness (+ stateroot, only if
# RG_FUZZ_STATEROOT_URLS is set — see header GAP), against NODE_PIDS discovered once at preflight.
# Returns non-zero iff any oracle tripped.
#
# STDOUT CONTRACT: oracle_crash.sh / oracle_liveness.sh / oracle_stateroot.sh communicate
# pass/fail via EXIT CODE, but they also print human-readable lines (e.g. oracle_crash.sh's
# "CRASH: pid <N> is gone") to THEIR OWN STDOUT. Every invocation below is explicitly redirected
# to stderr (`>&2`) so this function's own stdout stays empty — callers that command-substitute a
# result out of a call chain running through here (bisection, notably — see _fuzz_bisect) must
# never have oracle chatter leak into that captured value. Do not remove these redirects.
#
# Also sets globals _FUZZ_LAST_CRASH_TRIPPED / _FUZZ_LAST_LIVENESS_TRIPPED /
# _FUZZ_LAST_STATEROOT_TRIPPED (0/1, reset at the top of every call) so a caller can tell WHICH
# oracle tripped — _fuzz_run uses _FUZZ_LAST_CRASH_TRIPPED to decide whether a batch trip was a
# genuine crash (pids actually gone) vs a liveness-only halt (pids still alive), which is exactly
# the distinction RG_FUZZ_RESTART_CMD's gating (_fuzz_should_bisect) needs.
_fuzz_oracle_check_once() {
    local label="$1" rc=0
    _FUZZ_LAST_CRASH_TRIPPED=0
    _FUZZ_LAST_LIVENESS_TRIPPED=0
    _FUZZ_LAST_STATEROOT_TRIPPED=0

    echo ">> fuzz_bcos: oracle check ($label): crash" >&2
    if ! bash "$SCRIPT_DIR/oracle_crash.sh" --once "${NODE_PIDS[@]}" >&2; then
        rc=1
        _FUZZ_LAST_CRASH_TRIPPED=1
    fi
    echo ">> fuzz_bcos: oracle check ($label): liveness" >&2
    if ! bash "$SCRIPT_DIR/oracle_liveness.sh" -r "$RG_FUZZ_WEB3_URL" >&2; then
        rc=1
        _FUZZ_LAST_LIVENESS_TRIPPED=1
    fi
    if [[ -n "${RG_FUZZ_STATEROOT_URLS:-}" ]]; then
        echo ">> fuzz_bcos: oracle check ($label): stateroot" >&2
        local height
        height="$(_fuzz_rpc_height)"
        if [[ -z "$height" ]]; then
            echo "WARN: fuzz_bcos: could not read block height for stateroot oracle ($label)" >&2
        else
            local -a urls=("$RG_FUZZ_WEB3_URL") extra rflags=()
            IFS=',' read -r -a extra <<< "$RG_FUZZ_STATEROOT_URLS"
            urls+=("${extra[@]}")
            local u
            for u in "${urls[@]}"; do rflags+=(-r "$u"); done
            if ! bash "$SCRIPT_DIR/oracle_stateroot.sh" -b "$height" "${rflags[@]}" >&2; then
                rc=1
                _FUZZ_LAST_STATEROOT_TRIPPED=1
            fi
        fi
    else
        echo ">> fuzz_bcos: oracle check ($label): stateroot SKIPPED (GAP: no per-node RPC URLs wired — set RG_FUZZ_STATEROOT_URLS)" >&2
    fi
    return $rc
}

_fuzz_preflight() {
    echo ">> fuzz_bcos: preflight: discovering live node PIDs under $NODE_DIR"
    mapfile -t NODE_PIDS < <(_fuzz_discover_pids)
    if [[ ${#NODE_PIDS[@]} -eq 0 ]]; then
        echo "ERROR: fuzz_bcos: could not discover any live fisco-bcos node PIDs under $NODE_DIR — bring up a chain first (see apply_profile.sh)." >&2
        return 1
    fi
    echo ">> fuzz_bcos: preflight: discovered PIDs: ${NODE_PIDS[*]}"

    echo ">> fuzz_bcos: preflight: confirming BCOS RPC answers at $BCOS_RPC_URL"
    local resp
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"getBlockNumber\",\"params\":[\"${BCOS_GROUP_ID}\",\"\"],\"id\":1}" \
        "$BCOS_RPC_URL" 2>/dev/null || true)"
    if [[ -z "$resp" || "$resp" != *'"result"'* ]]; then
        echo "ERROR: fuzz_bcos: BCOS RPC at $BCOS_RPC_URL did not answer getBlockNumber cleanly — is a chain up? response: $resp" >&2
        return 1
    fi
    echo ">> fuzz_bcos: preflight: BCOS RPC OK"

    [[ -x "$JAVA_BIN" ]] || command -v "$JAVA_BIN" >/dev/null 2>&1 || {
        echo "ERROR: fuzz_bcos: JAVA_BIN '$JAVA_BIN' not found on PATH" >&2
        return 1
    }
    [[ -f "$FUZZ_JAR" ]] || {
        echo "ERROR: fuzz_bcos: FUZZ_JAR not found at $FUZZ_JAR — build it first: (cd tools/tamper-fuzz && ./gradlew shadowJar)" >&2
        return 1
    }

    echo ">> fuzz_bcos: preflight: baseline oracle pass (a pre-existing halt must not be blamed on the fuzzer)"
    if ! _fuzz_oracle_check_once "baseline"; then
        echo "ERROR: fuzz_bcos: baseline oracle check failed BEFORE any fuzzing — the chain is already unhealthy; refusing to start." >&2
        return 1
    fi
    echo ">> fuzz_bcos: preflight: baseline OK"
    return 0
}

_fuzz_write_case() {
    local path="$1" profile="$2" hex="$3" seed="$4" idx="$5"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<CASEEOF
# auto-distilled by fuzz_bcos.sh from a confirmed oracle trip (seed=$seed idx=$idx). This case
# records the TARGET post-fix behavior (expect_oracle=reject) per scenarios/README.md's flywheel —
# today, before the underlying defect is fixed, replaying this case is expected to FAIL (or
# reproduce the crash outright); it starts passing, and becomes a real regression guard, once the
# node is fixed to cleanly reject this input instead. See failures.jsonl for the still-open defect.
[case]
profile = $profile
input = curl -sS -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"sendTransaction","params":["${BCOS_GROUP_ID}","","$hex"],"id":1}' $BCOS_RPC_URL
expect_oracle = reject
CASEEOF
    echo ">> fuzz_bcos: distilled case written to $path" >&2
}

# _fuzz_reinject_range_and_check <seed> <strategy> <lo> <hi> — regenerate mutants idx=[lo,hi] for
# (seed,strategy) by calling `fuzz (hi+1) seed strategy` and keeping only the tail lo..hi. This
# replays the EXACT SAME Random draw sequence idx 0..hi regardless of the requested count (see
# FuzzGenerator's determinism contract), so lines lo..hi are byte-identical to what they were
# inside the original full batch. Injects each, then runs one crash+liveness(+stateroot) check.
#
# POLARITY: this function's return value is the bisection PROBE contract (0 = trip REPRODUCED in
# this range, 1 = clean) — the contract _fuzz_bisect and its test mocks assume. That is the
# OPPOSITE of _fuzz_oracle_check_once's own return (0 = all oracles clean). Do not call
# _fuzz_oracle_check_once bare as this function's last statement and let its exit code fall
# through — that inverts the polarity (a clean cluster would then read as "reproduced" and vice
# versa; this exact inversion previously made bisection converge on a non-crashing idx instead of
# the real crasher — see tests/fuzz_bcos_test.sh's probe-polarity regression). Always translate
# explicitly, as below.
_fuzz_reinject_range_and_check() {
    local seed="$1" strategy="$2" lo="$3" hi="$4"
    local count=$(( hi + 1 ))
    local tail_n=$(( hi - lo + 1 ))
    local idx kind detail hex
    while IFS=$'\t' read -r idx kind detail hex; do
        [[ -z "${hex:-}" ]] && continue
        _fuzz_inject_and_classify "$hex" >/dev/null
    done < <("$JAVA_BIN" -jar "$FUZZ_JAR" fuzz "$count" "$seed" "$strategy" | tail -n "$tail_n")
    if _fuzz_oracle_check_once "bisect[$lo,$hi]"; then
        return 1   # oracles clean => trip did NOT reproduce in this range
    fi
    return 0       # an oracle tripped => reproduced here
}

# _fuzz_restart_and_confirm_health — run RG_FUZZ_RESTART_CMD, re-discover NODE_PIDS (a restart
# almost always means fresh PIDs), then re-confirm health via one full oracle pass. Returns 0 iff
# the restart command itself succeeded, at least one PID was found afterward, AND the oracle pass
# came back clean. Caller (the restart-aware probe wrapper below) treats a non-zero return here as
# "cannot safely continue bisecting" and aborts rather than probing an unconfirmed cluster.
_fuzz_restart_and_confirm_health() {
    echo ">> fuzz_bcos: restart: running RG_FUZZ_RESTART_CMD to restore cluster health" >&2
    if ! bash -c "$RG_FUZZ_RESTART_CMD" >&2; then
        echo "ERROR: fuzz_bcos: restart: RG_FUZZ_RESTART_CMD failed" >&2
        return 1
    fi
    mapfile -t NODE_PIDS < <(_fuzz_discover_pids)
    if [[ ${#NODE_PIDS[@]} -eq 0 ]]; then
        echo "ERROR: fuzz_bcos: restart: no live node PIDs discovered under $NODE_DIR after RG_FUZZ_RESTART_CMD" >&2
        return 1
    fi
    echo ">> fuzz_bcos: restart: discovered PIDs: ${NODE_PIDS[*]}" >&2
    if ! _fuzz_oracle_check_once "post-restart"; then
        echo "ERROR: fuzz_bcos: restart: cluster still unhealthy after RG_FUZZ_RESTART_CMD" >&2
        return 1
    fi
    echo ">> fuzz_bcos: restart: cluster confirmed healthy" >&2
    return 0
}

# _fuzz_reinject_range_and_check_restarting <seed> <strategy> <lo> <hi> — the restart-aware probe:
# if RG_FUZZ_RESTART_CMD is set, restore+reconfirm health BEFORE injecting this half (so the probe
# actually tests "does THIS half alone reproduce the trip against a known-healthy cluster", not
# "is the cluster still dead from before"); if unset, behaves exactly like the plain
# _fuzz_reinject_range_and_check (no restart attempted — appropriate for a liveness-only halt
# where the node is still alive and probeable). Returns 0 (this range reproduces the trip), 1
# (clean), or 2 (ABORT — the restart was configured but did not bring the cluster back healthy;
# bisection cannot safely continue). This is the default probe_fn for _fuzz_bisect.
_fuzz_reinject_range_and_check_restarting() {
    local seed="$1" strategy="$2" lo="$3" hi="$4"
    if [[ -n "${RG_FUZZ_RESTART_CMD:-}" ]]; then
        if ! _fuzz_restart_and_confirm_health; then
            return 2
        fi
    fi
    _fuzz_reinject_range_and_check "$seed" "$strategy" "$lo" "$hi"
}

# _fuzz_bisect <seed> <strategy> <lo> <hi> [probe_fn] — narrow [lo,hi] within one tripped batch to
# a single culprit idx (see header's single-input-causality note). probe_fn defaults to
# _fuzz_reinject_range_and_check_restarting; tests inject a mock here (see
# tests/fuzz_bcos_test.sh) to exercise the pure control flow without a live chain or java. Prints
# "<lo> <hi>" on stdout ONLY — no other output from this function or from probe_fn reaches stdout
# (probe_fn's own stdout is explicitly redirected to stderr at the call site below, in addition to
# _fuzz_oracle_check_once's own redirects — belt and suspenders, since a probe_fn a caller supplies
# is not guaranteed to redirect internally itself). Returns 0 on normal completion (the printed
# range is either a singleton culprit or an unresolved cumulative-state range) or 2 if probe_fn
# signaled ABORT (restart failed mid-bisection) — the printed range is then just wherever bisection
# had gotten to, not a verdict.
_fuzz_bisect() {
    local seed="$1" strategy="$2" lo="$3" hi="$4"
    local probe_fn="${5:-_fuzz_reinject_range_and_check_restarting}"
    while ! _fuzz_bisect_done "$lo" "$hi"; do
        local llo lhi ulo uhi pc
        read -r llo lhi < <(_fuzz_bisect_lower_half "$lo" "$hi")
        echo ">> fuzz_bcos: bisect: testing lower half [$llo,$lhi] of [$lo,$hi] (seed=$seed)" >&2
        pc=0
        "$probe_fn" "$seed" "$strategy" "$llo" "$lhi" >&2 || pc=$?
        if [[ "$pc" == 0 ]]; then
            lo="$llo"; hi="$lhi"
            continue
        elif [[ "$pc" == 2 ]]; then
            echo "ERROR: fuzz_bcos: bisect: ABORTED — probe signaled it could not confirm cluster health for [$llo,$lhi]" >&2
            echo "$lo $hi"
            return 2
        fi
        read -r ulo uhi < <(_fuzz_bisect_upper_half "$lo" "$hi")
        echo ">> fuzz_bcos: bisect: lower half clean; testing upper half [$ulo,$uhi] (seed=$seed)" >&2
        pc=0
        "$probe_fn" "$seed" "$strategy" "$ulo" "$uhi" >&2 || pc=$?
        if [[ "$pc" == 0 ]]; then
            lo="$ulo"; hi="$uhi"
            continue
        elif [[ "$pc" == 2 ]]; then
            echo "ERROR: fuzz_bcos: bisect: ABORTED — probe signaled it could not confirm cluster health for [$ulo,$uhi]" >&2
            echo "$lo $hi"
            return 2
        fi
        echo "WARN: fuzz_bcos: bisect: neither half of [$lo,$hi] reproduced alone (against a confirmed-healthy cluster) — possible cumulative-state trip (see header); recording the whole range as the culprit" >&2
        break
    done
    echo "$lo $hi"
    return 0
}

# _fuzz_run <outdir> <base_seed> <iters> <sec> <batch> <strategy> — the main batch loop. Live IO
# throughout; NOT exercised by tests. Returns non-zero iff an oracle tripped during the run (pure
# rejections are exit 0, per header).
_fuzz_run() {
    local outdir="$1" base_seed="$2" iters="$3" sec="$4" batch_size="$5" strategy="$6"
    local mode value
    read -r mode value < <(_fuzz_plan_mode "$iters" "$sec")

    local start_ts batch_idx=0 oracle_tripped=0 case_written=""
    local -a all_classes=()
    start_ts="$(date +%s)"

    while true; do
        if [[ "$mode" == "iters" ]]; then
            (( batch_idx >= value )) && break
        else
            local now elapsed
            now="$(date +%s)"
            elapsed=$(( now - start_ts ))
            (( elapsed >= value )) && break
        fi

        local seed
        seed="$(_fuzz_batch_seed "$base_seed" "$batch_idx")"
        echo ">> fuzz_bcos: batch $batch_idx (seed=$seed strategy=$strategy size=$batch_size)"

        local -a classes=()
        local idx kind detail hex
        while IFS=$'\t' read -r idx kind detail hex; do
            [[ -z "${hex:-}" ]] && continue
            classes+=("$(_fuzz_inject_and_classify "$hex")")
        done < <("$JAVA_BIN" -jar "$FUZZ_JAR" fuzz "$batch_size" "$seed" "$strategy")
        all_classes+=("${classes[@]}")
        echo ">> fuzz_bcos: batch $batch_idx tally: $(_fuzz_tally "${classes[@]}")"

        local batch_trip_rc=0
        _fuzz_oracle_check_once "batch$batch_idx" || batch_trip_rc=$?
        if [[ "$batch_trip_rc" == 0 ]]; then
            echo "OK: fuzz_bcos: batch $batch_idx clean"
        else
            oracle_tripped=1
            # Capture the trip type BEFORE any further oracle checks (bisection/restart below
            # will overwrite these globals on their own subsequent calls).
            local crash_was_real="$_FUZZ_LAST_CRASH_TRIPPED"
            local restart_cmd_set=0
            [[ -n "${RG_FUZZ_RESTART_CMD:-}" ]] && restart_cmd_set=1

            local blo=0 bhi=$((batch_size - 1))
            local resolved=0 aborted=0

            if ! _fuzz_should_bisect "$restart_cmd_set" "$crash_was_real"; then
                echo "TRIP: fuzz_bcos: batch $batch_idx tripped the CRASH oracle (nodes actually died) — RG_FUZZ_RESTART_CMD is not set, so re-injecting into a dead node cannot isolate a culprit. Bisection SKIPPED; recording the whole batch range." >&2
                failures_append "$outdir" "${RG_FUZZ_PROFILE:-unknown}" "exploration" "crash" "高" \
                    "fuzz_bcos.sh oracle trip: seed=$seed idx range [$blo,$bhi] batch=$batch_idx strategy=$strategy — crash-bisection SKIPPED: RG_FUZZ_RESTART_CMD is unset and the nodes are dead. Set RG_FUZZ_RESTART_CMD to a cluster-restart command to isolate a single input." \
                    "java -jar $FUZZ_JAR fuzz $((bhi + 1)) $seed $strategy | tail -n $((bhi - blo + 1))" \
                    "$outdir" "unknown"
            else
                echo "TRIP: fuzz_bcos: batch $batch_idx tripped an oracle — bisecting to isolate the culprit idx" >&2
                local range bisect_rc=0
                range="$(_fuzz_bisect "$seed" "$strategy" 0 $((batch_size - 1)))" || bisect_rc=$?
                read -r blo bhi <<< "$range"
                if [[ "$bisect_rc" == 2 ]]; then
                    aborted=1
                    echo "ABORT: fuzz_bcos: batch $batch_idx bisection aborted — RG_FUZZ_RESTART_CMD did not bring the cluster back healthy mid-bisection (last known range [$blo,$bhi])" >&2
                    failures_append "$outdir" "${RG_FUZZ_PROFILE:-unknown}" "exploration" "crash" "高" \
                        "fuzz_bcos.sh oracle trip: seed=$seed idx range [$blo,$bhi] batch=$batch_idx strategy=$strategy — bisection ABORTED: RG_FUZZ_RESTART_CMD failed to restore a healthy cluster mid-bisection" \
                        "java -jar $FUZZ_JAR fuzz $((bhi + 1)) $seed $strategy | tail -n $((bhi - blo + 1))" \
                        "$outdir" "unknown"
                elif [[ "$blo" == "$bhi" ]]; then
                    resolved=1
                    echo "CULPRIT: fuzz_bcos: seed=$seed idx=$blo (batch $batch_idx)"
                    local culprit_hex
                    culprit_hex="$("$JAVA_BIN" -jar "$FUZZ_JAR" fuzz $((blo + 1)) "$seed" "$strategy" | tail -n1 | cut -f4)"
                    local case_file="$SCRIPT_DIR/../scenarios/$(_fuzz_case_filename "$seed" "$blo")"
                    _fuzz_write_case "$case_file" "${RG_FUZZ_PROFILE:-profiles/production-enterprise.profile}" \
                        "$culprit_hex" "$seed" "$blo"
                    case_written="$case_file"
                    failures_append "$outdir" "${RG_FUZZ_PROFILE:-unknown}" "exploration" "crash" "高" \
                        "fuzz_bcos.sh oracle trip: seed=$seed idx=$blo strategy=$strategy batch=$batch_idx" \
                        "java -jar $FUZZ_JAR fuzz $((blo + 1)) $seed $strategy | tail -n1 | cut -f4" \
                        "$outdir" "unknown"
                else
                    echo "CULPRIT-RANGE: fuzz_bcos: seed=$seed idx range [$blo,$bhi] unresolved (neither half reproduced alone against a confirmed-healthy cluster)"
                    failures_append "$outdir" "${RG_FUZZ_PROFILE:-unknown}" "exploration" "crash" "高" \
                        "fuzz_bcos.sh oracle trip: seed=$seed idx range [$blo,$bhi] UNRESOLVED strategy=$strategy batch=$batch_idx" \
                        "java -jar $FUZZ_JAR fuzz $((bhi + 1)) $seed $strategy | tail -n $((bhi - blo + 1))" \
                        "$outdir" "unknown"
                fi
            fi

            # An abort means we can no longer trust the cluster's state at all — stop
            # unconditionally, RG_FUZZ_CONTINUE does not override this. Otherwise, the normal
            # stop-unless-RG_FUZZ_CONTINUE=1 policy applies.
            if [[ "$aborted" == 1 || "${RG_FUZZ_CONTINUE:-0}" != 1 ]]; then
                if [[ "$aborted" == 1 ]]; then
                    echo ">> fuzz_bcos: stopping (bisection aborted — cannot safely continue against an unconfirmed cluster)"
                else
                    echo ">> fuzz_bcos: stopping (a confirmed oracle trip is a finding; set RG_FUZZ_CONTINUE=1 to keep going)"
                fi
                batch_idx=$((batch_idx + 1))
                break
            fi
        fi

        batch_idx=$((batch_idx + 1))
    done

    # End-of-run cluster restore: if we stopped on a trip and a restart command is configured,
    # run it once more (best-effort) so the box isn't left with a dead/degraded chain. If none is
    # configured, say so explicitly — the caller is responsible for restarting manually.
    if [[ "$oracle_tripped" == 1 ]]; then
        if [[ -n "${RG_FUZZ_RESTART_CMD:-}" ]]; then
            echo ">> fuzz_bcos: end-of-run: restoring cluster via RG_FUZZ_RESTART_CMD" >&2
            if bash -c "$RG_FUZZ_RESTART_CMD" >&2; then
                echo ">> fuzz_bcos: end-of-run: cluster restored" >&2
            else
                echo "WARN: fuzz_bcos: end-of-run: RG_FUZZ_RESTART_CMD failed — the cluster may still be down, restart it manually" >&2
            fi
        else
            echo ">> fuzz_bcos: end-of-run: RG_FUZZ_RESTART_CMD not set — the cluster is left as-is; restart it manually if this run ended on a trip" >&2
        fi
    fi

    echo "== fuzz_bcos report =="
    echo "batches: $batch_idx"
    echo "injected: ${#all_classes[@]}"
    echo "tally: $(_fuzz_tally "${all_classes[@]}")"
    echo "oracle_tripped: $oracle_tripped"
    [[ -n "$case_written" ]] && echo "case: $case_written"

    return $oracle_tripped
}

# ---------------------------------------------------------------------------
# Main — only runs when this file is executed directly, not when sourced. Sourcing (e.g. from
# tests/fuzz_bcos_test.sh) must only pick up the function definitions above, never getopts parsing
# or any live-chain IO, matching scripts/oracle_liveness.sh's own execution guard exactly.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    OUTDIR="./nodes-release-gate-fuzz"
    DRY_RUN=0

    args=()
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]+"${args[@]}"}"

    while getopts "o:h" opt; do
        case "$opt" in
            o) OUTDIR="$OPTARG" ;;
            h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "bad flag; -h for help" >&2; exit 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    BASE_SEED="${RG_FUZZ_SEED:-42}"
    ITERS="${RG_FUZZ_ITERS:-20}"
    SEC="${RG_FUZZ_SEC:-0}"
    BATCH="${RG_FUZZ_BATCH:-100}"
    STRATEGY="${RG_FUZZ_STRATEGY:-both}"

    if [[ "$DRY_RUN" == 1 ]]; then
        _fuzz_print_dry_plan "$BASE_SEED" "$ITERS" "$SEC" "$BATCH" "$STRATEGY"
        exit 0
    fi

    mkdir -p "$OUTDIR"
    source "$SCRIPT_DIR/failures_lib.sh"

    if ! _fuzz_preflight; then
        exit 1
    fi

    _fuzz_run "$OUTDIR" "$BASE_SEED" "$ITERS" "$SEC" "$BATCH" "$STRATEGY"
    exit $?
fi
