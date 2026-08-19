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
#   profile = <a bare logical profile name (e.g. "production-enterprise", resolved via
#              ${FBT_PROFILE_DIR:-<repo>/profiles}/<name>.profile), OR a path relative to this
#              .case file's own dir, OR an absolute path>                          (required —
#              see _run_case_resolve_profile, the single place this three-way resolution happens)
#   input = <the command the exploration layer used to reproduce the failure — a console
#            invocation, a curl to the Web3 RPC, or similar>          (required)
#   expect_oracle = pass | reject                                     (required)
#     pass    — the input is a VALID operation. Case PASSES iff the input applied successfully
#               (exit 0) AND none of the three gate oracles trip (crash / consensus-halt /
#               state-mismatch all clean).
#     reject  — the input is malformed/malicious and SHOULD be refused. Case PASSES iff the
#               input was rejected (nonzero exit) AND the node stayed alive (crash oracle does
#               NOT trip) — the same false-green guard scripts/scenarios/scenario_malformed.sh's
#               _mal_verdict uses (rejected==1 && alive==1): a node that crashed while
#               "rejecting" is a FAIL, not a clean reject.
#   In BOTH modes, this is a release gate whose job is "confirm no exceptions" — a crash /
#   consensus-halt / state-mismatch oracle trip is ALWAYS a case FAIL. There is no expect_oracle
#   value under which a crash is an expected, passing outcome; see case_verdict below, the single
#   place this is decided.
#
# Real-run (no --dry-run; needs a live fisco-bcos binary — NOT exercised by this skill's own
# tests, since there is no binary in this environment):
#   1. apply_profile.sh brings up the case's declared profile onto a local AIR cluster.
#   2. `input` is applied verbatim via `bash -c`, with its exit status captured (not allowed to
#      abort this script — see the `set -euo pipefail` note at the input-apply call site). GAP:
#      run_case.sh does not validate or sandbox this command in any way — it is whatever shell
#      command the exploration layer used against the live cluster (console.sh, curl, …), and
#      trusting it is a documented assumption inherited straight from the .case file's author.
#   3. Node PIDs and the Web3 RPC URL are discovered the same way gate.sh's real-run does (see
#      scripts/gate.sh's discovery block); the three oracles run once, one-shot, matching
#      gate.sh's run_oracles_once. case_verdict combines the input's exit status and the three
#      oracle results into the single PASS/FAIL call per expect_oracle above.
set -euo pipefail

# Requires bash 4+ (this mirrors apply_profile.sh's guard even though run_case.sh itself has no
# associative arrays yet, so a future real-run addition that sources profile_lib.sh — which does
# need bash 4 — fails the same clear way up front instead of a cryptic error mid-run).
if (( BASH_VERSINFO[0] < 4 )); then
    echo "run_case.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fd 3 event protocol (design doc §8). Sourced and armed BEFORE any flag parsing: a usage error
# that exits two lines from now must still produce a command_finished, or the host sees a
# subprocess that died without terminating and reports its own bug (40) for what is really a
# config error (20). Every call is a no-op when fd 3 is not open, so standalone runs are unchanged.
source "$SCRIPT_DIR/event_lib.sh"
event_begin_command run_case.sh

DRY_RUN=0
# Host-provided workspace; see the same note in gate.sh. The old fixed name is the standalone
# fallback.
CLUSTER_OUTDIR="./nodes-release-gate-case"

# Pull the long flags out before getopts sees the rest (getopts only knows short opts).
#
# -o is pulled out HERE rather than left to getopts, because getopts stops at the first non-option
# argument and the case path IS one: `run_case.sh some.case -o dir` would silently ignore -o and
# build the cluster in the default directory. That is the order a person naturally types, and
# silently using the wrong workspace is worse than any parsing purity.
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -o|--outdir)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a directory. -h for help." >&2; exit 2; }
            CLUSTER_OUTDIR="$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
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
[[ -f "$CASE_PATH" ]] || { echo "ERROR: case not found: $CASE_PATH" >&2; exit 2; }

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

# _run_case_resolve_profile <spec> <case_dir> — resolve a .case file's `profile =` field to an
# absolute .profile path. Three forms, checked in order:
#   - absolute (spec starts with `/`)  -> returned as-is, NEVER joined to case_dir (an already-
#                                          absolute path means something specific; joining it to
#                                          case_dir would silently produce a different, wrong path)
#   - contains a `/` (relative)        -> resolved relative to case_dir (the .case file's own dir)
#   - bare logical name (no `/` at all) -> ${FBT_PROFILE_DIR:-<repo>/profiles}/<spec>.profile, the
#                                          same logical-name convention scenario_upgrade.sh's own
#                                          profile_path resolution note documents
# Pure — no IO, no file-existence check (the caller's own `[[ -f "$CASE_PROFILE" ]]` guard right
# after this call site does that). Ends with an explicit `return 0` — see the module's
# trailing-`[[ ]]`-under-`set -e` trap note: the last statement here is a plain `echo` inside an
# if/elif/else, which already returns 0 on its own, but the explicit return keeps that fact from
# depending on which branch ran.
_run_case_resolve_profile() {
    local spec="$1" case_dir="$2"
    if [[ "$spec" == /* ]]; then
        echo "$spec"
    elif [[ "$spec" == */* ]]; then
        echo "$case_dir/$spec"
    else
        echo "${FBT_PROFILE_DIR:-$SCRIPT_DIR/../profiles}/$spec.profile"
    fi
    return 0
}

[[ -z "$CASE_PROFILE" ]] && { echo "ERROR: $CASE_PATH: [case] profile= is required" >&2; exit 2; }
[[ -z "$CASE_INPUT" ]] && { echo "ERROR: $CASE_PATH: [case] input= is required" >&2; exit 2; }
[[ -z "$CASE_EXPECT_ORACLE" ]] && { echo "ERROR: $CASE_PATH: [case] expect_oracle= is required" >&2; exit 2; }

case "$CASE_EXPECT_ORACLE" in
    pass|reject) ;;
    *)
        echo "ERROR: $CASE_PATH: expect_oracle '$CASE_EXPECT_ORACLE' unknown — expected one of: pass reject" >&2
        exit 2
        ;;
esac

# case_verdict <expect> <input_rc> <crash_tripped> <liveness_tripped> <stateroot_tripped> — pure
# function, no IO; the ONE place expect_oracle's pass|reject semantics are decided (see the
# expect_oracle header comment above for the prose version). Returns 0 (CASE PASS) / 1 (CASE
# FAIL):
#   - any oracle trip (crash/liveness/stateroot) is ALWAYS a FAIL, in both modes — a release gate
#     confirms no exceptions; a crash is never an expected, passing outcome regardless of what a
#     .case declares.
#   - otherwise, expect=pass requires input_rc==0 (the input applied without being refused);
#     expect=reject requires input_rc!=0 (the input was refused) — mirroring
#     scripts/scenarios/scenario_malformed.sh's _mal_verdict (rejected==1 && alive==1), with
#     "alive" folded into the oracle-trip check above rather than passed separately.
case_verdict() {
    local expect="$1" input_rc="$2" crash_tripped="$3" liveness_tripped="$4" stateroot_tripped="$5"

    if [[ "$crash_tripped" == 1 || "$liveness_tripped" == 1 || "$stateroot_tripped" == 1 ]]; then
        return 1
    fi

    case "$expect" in
        pass)   [[ "$input_rc" == 0 ]] ;;
        reject) [[ "$input_rc" != 0 ]] ;;
    esac
}

if [[ "$DRY_RUN" == 1 ]]; then
    echo "== run_case dry-run =="
    echo "case: $CASE_PATH"
    echo "profile: $CASE_PROFILE"
    echo "input: $CASE_INPUT"
    echo "expect_oracle: $CASE_EXPECT_ORACLE"
    echo "workspace: $CLUSTER_OUTDIR"
    exit 0
fi

# ---------------------------------------------------------------------------
# Real-run — needs live chain. Never reached from --dry-run.
# ---------------------------------------------------------------------------

# Resolve the (possibly logical) `profile =` field to an absolute path now — the dry-run block
# above already exited with the raw, unresolved value (stable/logical, per _run_case_resolve_profile's
# own doc), so only the real-run path below ever sees the resolved absolute path.
CASE_PROFILE="$(_run_case_resolve_profile "$CASE_PROFILE" "$(dirname "$CASE_PATH")")"
# exit 2 = config_error under the event protocol: a .case naming a profile that does not
# exist is the author's mistake, not an engine fault (which exit 1 would report as 40).
[[ -f "$CASE_PROFILE" ]] || { echo "ERROR: $CASE_PATH: profile not found: $CASE_PROFILE" >&2; exit 2; }

APPLY_PROFILE="$SCRIPT_DIR/apply_profile.sh"
[[ -f "$APPLY_PROFILE" ]] || { event_set_outcome infra_error; echo "ERROR: apply_profile.sh not found at $APPLY_PROFILE" >&2; exit 1; }

echo ">> [1/3] apply_profile (needs live chain): bringing up cluster for $CASE_PROFILE"
bash "$APPLY_PROFILE" -p "$CASE_PROFILE" -o "$CLUSTER_OUTDIR"

CLUSTER_OUTDIR_ABS="$(cd "$CLUSTER_OUTDIR" && pwd)"
NODE_DIR="$CLUSTER_OUTDIR_ABS/127.0.0.1"

# RPC URL: derive from node0's FINAL config.ini via _primary_web3_url — see gate.sh's own
# comment on this (same Design Decision rev3 #2 fix: a raw PROFILE_CONFIG read misses a host
# WEB3_BASE override applied by apply_profile.sh). run_case.sh has no other use for PROFILE_*
# (unlike gate.sh, which still reads PROFILE_GENESIS[compatibility_version] for its own log
# lines), so profile_lib.sh/profile_load are deliberately NOT sourced here.
source "$SCRIPT_DIR/oracle_lib.sh"
source "$SCRIPT_DIR/failures_lib.sh"
RPC_URL="$(_primary_web3_url "$NODE_DIR")" || {
    event_set_outcome infra_error
    echo "ERROR: run_case: could not derive the primary Web3 RPC URL from $NODE_DIR/node0/config.ini" >&2
    exit 1
}

# PID discovery mirrors gate.sh's own (see scripts/gate.sh's discovery block for the documented
# assumption about cluster_up.sh's process-launch layout this relies on).
mapfile -t node_pids < <(pgrep -f "$NODE_DIR/" 2>/dev/null || true)
if [[ ${#node_pids[@]} -eq 0 ]]; then
    event_set_outcome infra_error
    echo "ERROR: could not discover any live fisco-bcos node PIDs under $NODE_DIR — apply_profile.sh may not have brought up a chain." >&2
    exit 1
fi
echo ">> discovered node PIDs: ${node_pids[*]}"

echo ">> [2/3] applying input (needs live chain): $CASE_INPUT"
# CRITICAL fix: under `set -euo pipefail` a bare `bash -c "$CASE_INPUT"` would abort this whole
# script the moment the input exits nonzero — exactly what happens for an expect_oracle=reject
# case where the input is SUPPOSED to be refused. Capture the exit status explicitly instead of
# letting it propagate; case_verdict (see above) is what decides whether that nonzero exit is a
# pass (rejected, as expected) or a fail (unexpectedly refused).
input_rc=0
bash -c "$CASE_INPUT" || input_rc=$?
echo ">> input exit status: $input_rc"

rpc_current_height() {
    local resp hex
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$RPC_URL" 2>/dev/null)" || { echo ""; return; }
    hex="$(printf '%s' "$resp" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    [[ -z "$hex" ]] && { echo ""; return; }
    printf '%d\n' "$hex"
}

# Every trip goes into the same local sink gate.sh writes, <cluster_outdir>/failures.jsonl.
# Without this a replay that reproduced a real crash -- three oracles tripping, the node gone --
# left no record anywhere but the terminal, which is the one place nobody reads afterwards. The
# flywheel's whole claim is that a confirmed defect becomes a durable artifact; a fixture that
# fires and records nothing breaks that at the last step.
_case_record() {
    # The version field is "unknown" rather than the profile's compatibility_version: run_case.sh
    # deliberately does not source profile_lib.sh (see the note above RPC_URL), and sourcing it for
    # one log field would pull the whole PROFILE_* machinery in behind it. The repro command and the
    # evidence directory carry what an investigator actually needs.
    failures_append "$CLUSTER_OUTDIR_ABS" "$(basename "$CASE_PROFILE")" \
        "case:$(basename "$CASE_PATH")" "$1" "高" "$2" \
        "bash $SCRIPT_DIR/run_case.sh $CASE_PATH" "$NODE_DIR" "unknown"
}

echo ">> [3/3] oracle sweep (needs live chain) — all three always run; a trip is a FAIL under either expect_oracle value (see case_verdict)"
crash_tripped=0
if ! bash "$SCRIPT_DIR/oracle_crash.sh" --once "${node_pids[@]}"; then
    crash_tripped=1
    _case_record crash "oracle_crash tripped replaying $(basename "$CASE_PATH")"
fi

liveness_tripped=0
if ! bash "$SCRIPT_DIR/oracle_liveness.sh" -r "$RPC_URL"; then
    liveness_tripped=1
    _case_record halt "oracle_liveness tripped replaying $(basename "$CASE_PATH")"
fi

stateroot_tripped=0
height="$(rpc_current_height)"
if [[ -z "$height" ]]; then
    echo "ERROR: could not read block height from $RPC_URL for stateroot oracle" >&2
    stateroot_tripped=1
else
    echo ">> stateroot @ $height (multi-node discovery under $NODE_DIR)"
    sr_rc=0
    _run_stateroot_oracle "$height" "$NODE_DIR" "" || sr_rc=$?
    if [[ "$sr_rc" == 3 ]]; then
        # Distinct exit path from a genuine oracle trip: <2 node RPCs discovered is an
        # infrastructure failure, not a case verdict — case_verdict has no way to say "the
        # stateroot oracle was never meaningfully consulted", so this exits directly instead of
        # folding it into stateroot_tripped and reporting a misleading CASE: FAIL.
        event_set_outcome infra_error
        echo "ERROR: run_case: stateroot: <2 node RPCs discovered under $NODE_DIR — infrastructure failure, refusing to judge $CASE_PATH" >&2
        bash "$NODE_DIR/stop_all.sh" || true
        exit 1
    elif [[ "$sr_rc" == 1 ]]; then
        stateroot_tripped=1
        _case_record state-mismatch "oracle_stateroot tripped at height $height replaying $(basename "$CASE_PATH")"
    fi
fi

bash "$NODE_DIR/stop_all.sh" || true

# Name the outcome at BOTH verdict points. Without this the rc fallback maps a failing case to
# engine_error -> exit 40, "fbt has a bug", for a replay that did exactly its job: a fixture that
# reproduced a real chain crash reported the HOST as broken. A case failing is a RESULT (10), the
# same as a scenario failing -- that distinction is the whole reason the exit codes exist.
# case_replayed is what puts this replay in the run's evidence matrix. gate.sh's sweep emits it for
# every fixture it runs; a standalone `fbt case run` emitted nothing, so `fbt report` could show the
# exit code and the defects but not WHICH fixture produced them.
if case_verdict "$CASE_EXPECT_ORACLE" "$input_rc" "$crash_tripped" "$liveness_tripped" "$stateroot_tripped"; then
    emit_event case_replayed file "$(basename "$CASE_PATH")" result "pass"
    event_set_outcome pass
    echo "CASE: PASS ($CASE_PATH)"
else
    emit_event case_replayed file "$(basename "$CASE_PATH")" result "fail"
    event_set_outcome gate_fail
    echo "CASE: FAIL ($CASE_PATH — expect_oracle=$CASE_EXPECT_ORACLE input_rc=$input_rc crash_tripped=$crash_tripped liveness_tripped=$liveness_tripped stateroot_tripped=$stateroot_tripped)"
    exit 1
fi
