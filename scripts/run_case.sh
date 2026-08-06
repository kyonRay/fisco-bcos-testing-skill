#!/usr/bin/env bash
# run_case.sh — replay a declarative regression .case file: bring up its declared profile,
# apply its declared input, and assert the result matches its declared expect_oracle.
#
# This is the flywheel: a failure the exploration layer confirms by hand gets distilled into a
# .case file dropped into scenarios/ (the top-level one — see scenarios/README.md for the
# distinction from scripts/scenarios/), and this script (or a future gate.sh case-sweep) re-runs
# it deterministically every round, so a fixed regression never silently comes back.
#
# Usage:
#   run_case.sh <case> [--dry-run] [-h]
#     <case>     path to a .case file (required)        e.g. scenarios/example.case
#     --dry-run  print the parsed profile/input/expect_oracle and exit — no apply_profile, no
#                chain, no oracle check. Parsing and field validation happen before this check,
#                so a malformed .case fails the same way with or without --dry-run.
#     -h         print this help and exit
#
# .case format (INI-like, single [case] section — see scripts/profile_lib.sh for the sibling
# .profile parser this format deliberately mirrors):
#   [case]
#   profile = <path to a .profile file, relative to the repo root>   (required)
#   input = <the command the exploration layer used to reproduce the failure — a console
#            invocation, a curl to the Web3 RPC, or similar>          (required)
#   expect_oracle = pass | crash | consensus_halt | state_mismatch    (required)
#     pass             — none of the three gate oracles should trip after applying input; this
#                        is also how a "the malicious input gets safely rejected" case is
#                        expressed (a rejected input trips no oracle).
#     crash / consensus_halt / state_mismatch
#                      — the named oracle (see gate.sh / scripts/oracle_*.sh) is expected to
#                        trip: a regression case for a still-open defect. The gate round SHOULD
#                        report FAIL until the defect is fixed; once fixed, this case starts
#                        failing its own assertion and must be updated to expect_oracle=pass.
#
# Real-run (no --dry-run; needs a live fisco-bcos binary — NOT exercised by this skill's own
# tests, since there is no binary in this environment):
#   1. apply_profile.sh brings up the case's declared profile onto a local AIR cluster.
#   2. `input` is applied verbatim via `bash -c`. GAP: run_case.sh does not validate or sandbox
#      this command in any way — it is whatever shell command the exploration layer used against
#      the live cluster (console.sh, curl, …), and trusting it is a documented assumption
#      inherited straight from the .case file's author.
#   3. Node PIDs and the Web3 RPC URL are discovered the same way gate.sh's real-run does (see
#      scripts/gate.sh's discovery block); the three oracles run once, one-shot, matching
#      gate.sh's run_oracles_once. The oracle named by expect_oracle (or all three, for "pass")
#      decides the verdict.
set -euo pipefail

# Requires bash 4+ (this mirrors apply_profile.sh's guard even though run_case.sh itself has no
# associative arrays yet, so a future real-run addition that sources profile_lib.sh — which does
# need bash 4 — fails the same clear way up front instead of a cryptic error mid-run).
if (( BASH_VERSINFO[0] < 4 )); then
    echo "run_case.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0

# Pull the long --dry-run flag out before getopts sees the rest (getopts only knows short opts).
args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

while getopts "h" opt; do
    case "$opt" in
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

CASE_PATH="${1:-}"
[[ -z "$CASE_PATH" ]] && { echo "ERROR: <case> path is required. -h for help." >&2; exit 2; }
[[ -f "$CASE_PATH" ]] || { echo "ERROR: case not found: $CASE_PATH" >&2; exit 1; }

# case_parse <path> — parse the [case] section into CASE_PROFILE / CASE_INPUT /
# CASE_EXPECT_ORACLE. Deliberately a plain-variable parse (not associative-array-based like
# profile_lib.sh) since a .case file has exactly one section with exactly three known keys.
CASE_PROFILE=""
CASE_INPUT=""
CASE_EXPECT_ORACLE=""
case_parse() {
    local path="$1" section="" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        if [[ "$line" =~ ^\[([a-zA-Z0-9_]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$section" == "case" && "$line" == *"="* ]]; then
            key="${line%%=*}"
            value="${line#*=}"
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            case "$key" in
                profile) CASE_PROFILE="$value" ;;
                input) CASE_INPUT="$value" ;;
                expect_oracle) CASE_EXPECT_ORACLE="$value" ;;
            esac
        fi
    done < "$path"
}
case_parse "$CASE_PATH"

[[ -z "$CASE_PROFILE" ]] && { echo "ERROR: $CASE_PATH: [case] profile= is required" >&2; exit 1; }
[[ -z "$CASE_INPUT" ]] && { echo "ERROR: $CASE_PATH: [case] input= is required" >&2; exit 1; }
[[ -z "$CASE_EXPECT_ORACLE" ]] && { echo "ERROR: $CASE_PATH: [case] expect_oracle= is required" >&2; exit 1; }

case "$CASE_EXPECT_ORACLE" in
    pass|crash|consensus_halt|state_mismatch) ;;
    *)
        echo "ERROR: $CASE_PATH: expect_oracle '$CASE_EXPECT_ORACLE' unknown — expected one of: pass crash consensus_halt state_mismatch" >&2
        exit 1
        ;;
esac

if [[ "$DRY_RUN" == 1 ]]; then
    echo "== run_case dry-run =="
    echo "case: $CASE_PATH"
    echo "profile: $CASE_PROFILE"
    echo "input: $CASE_INPUT"
    echo "expect_oracle: $CASE_EXPECT_ORACLE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Real-run — needs live chain. Never reached from --dry-run.
# ---------------------------------------------------------------------------

[[ -f "$CASE_PROFILE" ]] || { echo "ERROR: $CASE_PATH: profile not found: $CASE_PROFILE" >&2; exit 1; }

APPLY_PROFILE="$SCRIPT_DIR/apply_profile.sh"
[[ -f "$APPLY_PROFILE" ]] || { echo "ERROR: apply_profile.sh not found at $APPLY_PROFILE" >&2; exit 1; }

CLUSTER_OUTDIR="./nodes-release-gate-case"

echo ">> [1/3] apply_profile (needs live chain): bringing up cluster for $CASE_PROFILE"
bash "$APPLY_PROFILE" -p "$CASE_PROFILE" -o "$CLUSTER_OUTDIR"

CLUSTER_OUTDIR_ABS="$(cd "$CLUSTER_OUTDIR" && pwd)"
NODE_DIR="$CLUSTER_OUTDIR_ABS/127.0.0.1"

source "$SCRIPT_DIR/profile_lib.sh"
profile_load "$CASE_PROFILE"
web3_port="${PROFILE_CONFIG[web3_rpc.listen_port]:-8545}"
RPC_URL="http://127.0.0.1:${web3_port}"

# PID discovery mirrors gate.sh's own (see scripts/gate.sh's discovery block for the documented
# assumption about cluster_up.sh's process-launch layout this relies on).
mapfile -t node_pids < <(pgrep -f "$NODE_DIR/" 2>/dev/null || true)
if [[ ${#node_pids[@]} -eq 0 ]]; then
    echo "ERROR: could not discover any live fisco-bcos node PIDs under $NODE_DIR — apply_profile.sh may not have brought up a chain." >&2
    exit 1
fi
echo ">> discovered node PIDs: ${node_pids[*]}"

echo ">> [2/3] applying input (needs live chain): $CASE_INPUT"
bash -c "$CASE_INPUT"

rpc_current_height() {
    local resp hex
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$RPC_URL" 2>/dev/null)" || { echo ""; return; }
    hex="$(printf '%s' "$resp" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    [[ -z "$hex" ]] && { echo ""; return; }
    printf '%d\n' "$hex"
}

echo ">> [3/3] checking expect_oracle=$CASE_EXPECT_ORACLE (needs live chain)"
oracle_rc=0
case "$CASE_EXPECT_ORACLE" in
    crash)
        bash "$SCRIPT_DIR/oracle_crash.sh" --once "${node_pids[@]}" && oracle_rc=1 || oracle_rc=0
        ;;
    consensus_halt)
        bash "$SCRIPT_DIR/oracle_liveness.sh" -r "$RPC_URL" && oracle_rc=1 || oracle_rc=0
        ;;
    state_mismatch)
        height="$(rpc_current_height)"
        [[ -z "$height" ]] && { echo "ERROR: could not read block height from $RPC_URL" >&2; exit 1; }
        # GAP: only one -r URL is passed, mirroring gate.sh's run_oracles_once (see
        # scripts/gate.sh's oracle-check block) — oracle_stateroot.sh needs at least 2 to compare
        # and short-circuits OK (exit 0, "nothing to compare") with just one, so
        # expect_oracle=state_mismatch can never actually observe a divergence as written. Fixing
        # this needs sourcing a second node's RPC URL from the discovered cluster layout, which is
        # out of this task's scope; documenting the limitation here rather than silently inheriting it.
        bash "$SCRIPT_DIR/oracle_stateroot.sh" -b "$height" -r "$RPC_URL" && oracle_rc=1 || oracle_rc=0
        ;;
    pass)
        bash "$SCRIPT_DIR/oracle_crash.sh" --once "${node_pids[@]}" || oracle_rc=1
        bash "$SCRIPT_DIR/oracle_liveness.sh" -r "$RPC_URL" || oracle_rc=1
        height="$(rpc_current_height)"
        if [[ -z "$height" ]]; then
            echo "ERROR: could not read block height from $RPC_URL" >&2
            oracle_rc=1
        else
            bash "$SCRIPT_DIR/oracle_stateroot.sh" -b "$height" -r "$RPC_URL" || oracle_rc=1
        fi
        ;;
esac

bash "$NODE_DIR/stop_all.sh" || true

if [[ "$oracle_rc" == 1 ]]; then
    echo "CASE: FAIL ($CASE_PATH — did not match expect_oracle=$CASE_EXPECT_ORACLE)"
    exit 1
fi
echo "CASE: PASS ($CASE_PATH)"
