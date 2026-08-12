#!/usr/bin/env bash
# gate.sh — release-gate orchestrator. Applies a captured production profile
# to a local AIR cluster, runs the requested scenario families against it,
# monitors the three failure oracles throughout, and aggregates a single
# exit code: any oracle trip OR any scenario failure makes the run non-zero.
#
# Usage:
#   gate.sh -p <profile> [--scenarios a,b,c] [--dry-run] [-h]
#     -p  path to a .profile file (required)          e.g. profiles/production-enterprise.profile
#     --scenarios  comma-separated scenario names       (default: all of GATE_KNOWN_SCENARIOS)
#     --dry-run  print the profile name and the resolved scenario list, validate scenario
#                names via _gate_validate_scenarios, and exit — no chain, no oracles, no
#                scenario execution.
#     -h  print this help and exit
#
# Scenario selection is checked by _gate_validate_scenarios (see its own comment below) before
# anything else runs — gate.sh exits with whatever code the validator returns, so a bad selection
# aborts with a distinct, classified exit code instead of silently doing nothing or failing mid-run:
#   - 'upgrade' selected          -> 2 (config error; upgrade is not a gate.sh scenario — it needs
#                                       <old_bin> <new_bin> <target_ver> this bare-dispatch loop
#                                       can't supply; run it directly, see SKILL.md /
#                                       references/upgrade-path.md)
#   - unknown scenario name       -> 2 (config error)
#   - known name, not registered  -> 3 (engine/setup fault — its scripts/scenarios/scenario_
#                                       <name>.sh didn't source; should not happen for the four
#                                       default families, all of which self-register above)
#   - every requested name valid  -> 0, run proceeds
#
# GATE_KNOWN_SCENARIOS is exactly the four runnable families (ut, dual_rpc, malformed, jsd).
# scenario_upgrade.sh still self-registers into GATE_SCENARIOS (for callers that source it and
# call scenario_upgrade_run directly), but 'upgrade' is deliberately NOT a GATE_KNOWN_SCENARIOS
# member — see _gate_validate_scenarios.
#
# Real-run (no --dry-run; needs a live fisco-bcos binary — NOT exercised by this skill's own
# tests, since there is no binary in this environment):
#   1. apply_profile.sh brings up the cluster and replays the profile onto it; node PIDs and the
#      Web3 RPC URL are then discovered from the cluster's on-disk layout (see the discovery
#      block below — this is a documented assumption about that layout, verified only against a
#      live chain).
#   2. The three oracles run as ONE-SHOT checks (never a persistent background process) — once
#      as a baseline right after bring-up, and once again after each scenario. Each call runs to
#      completion and its real exit status is aggregated into oracle_tripped.
#   3. Each requested scenario name is looked up in GATE_SCENARIOS and run in turn — validation
#      above already guaranteed every requested name is known and registered, so there is no
#      runtime SKIP branch here.
#   4. The cluster is torn down.
#   5. Exit code aggregates: any oracle trip OR any scenario failure -> non-zero.
set -euo pipefail

# Requires bash 4+ (associative array GATE_SCENARIOS). Fail clearly instead of a cryptic
# `declare: -gA: invalid option` on stock macOS bash 3.2.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "gate.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fd 3 event protocol (design doc §8). Sourced and armed BEFORE any flag parsing: a usage error
# that exits two lines from now must still produce a command_finished, or the host sees a
# subprocess that died without terminating and reports its own bug (40) for what is really a
# config error (20). Every call is a no-op when fd 3 is not open, so standalone runs are unchanged.
source "$SCRIPT_DIR/event_lib.sh"
event_begin_command gate.sh

# Declarative list of valid scenario names, used by scenario-selection validation. Exactly the
# four runnable families — 'upgrade' is excluded on purpose (see _gate_validate_scenarios below):
# it needs <old_bin> <new_bin> <target_ver>, which this bare-dispatch loop cannot supply, so
# selecting it is a config error rather than something the default sweep silently skips.
GATE_KNOWN_SCENARIOS="ut dual_rpc malformed jsd"

# name -> function map, filled by conditionally sourcing scripts/scenarios/*.sh below. Empty
# (and that's fine) until Tasks 7-10 add scenario files.
declare -A GATE_SCENARIOS=()

# Conditional source: only files that exist are sourced, so an empty (or absent)
# scripts/scenarios/ dir is not an error. `shopt -s nullglob` makes the glob expand to nothing
# (instead of the literal, unmatched pattern string) when no *.sh files are present.
shopt -s nullglob
for f in "$SCRIPT_DIR"/scenarios/*.sh; do
    source "$f"
done
shopt -u nullglob

PROFILE_PATH=""
SCENARIOS_RAW=""
DRY_RUN=0
# The cluster directory is a host-provided workspace, not a fixed name in the current directory.
# The engine's cwd stays the repo root (design doc §7.3), so two concurrent runs cannot be isolated
# by chdir'ing -- only by being told where to build. The old hardcoded default stays as the
# standalone fallback.
CLUSTER_OUTDIR="./nodes-release-gate"

# Pull the long flags out before getopts sees the rest (getopts only knows short opts).
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenarios)
            # MINOR #1 fix: guard against --scenarios being the last token — reading $2
            # unconditionally under `set -u` would abort with a raw "unbound variable"
            # instead of a clean usage error.
            [[ $# -ge 2 ]] || { echo "ERROR: --scenarios requires a value (comma-separated names). -h for help." >&2; exit 2; }
            SCENARIOS_RAW="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

while getopts "p:o:h" opt; do
    case "$opt" in
        p) PROFILE_PATH="$OPTARG" ;;
        o) CLUSTER_OUTDIR="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done

[[ -z "$PROFILE_PATH" ]] && { echo "ERROR: -p <profile> is required. -h for help." >&2; exit 2; }
# exit 2, not 1: a profile that is not there is a CONFIGURATION error. The event
# protocol maps 2 to config_error (20, "fix your config") and every other non-zero to
# engine_error (40, "fbt has a bug") -- and exit 1 here really did report a mistyped
# -p as an fbt defect. gate_upgrade.sh already used 2; these three did not.
[[ -f "$PROFILE_PATH" ]] || { echo "ERROR: profile not found: $PROFILE_PATH" >&2; exit 2; }

profile_base="$(basename "$PROFILE_PATH")"
profile_name="${profile_base%.*}"

# Resolve the requested scenario list: --scenarios a,b,c, or every known scenario by default.
if [[ -n "$SCENARIOS_RAW" ]]; then
    IFS=',' read -r -a scenario_list <<< "$SCENARIOS_RAW"
    # MINOR #2 fix: trim leading/trailing whitespace from each name so
    # `--scenarios "ut, dual_rpc"` doesn't yield a " dual_rpc" element that fails the
    # known-scenario check with a confusing (leading-space) name in the error message.
    for i in "${!scenario_list[@]}"; do
        name="${scenario_list[$i]}"
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        scenario_list[$i]="$name"
    done
else
    read -r -a scenario_list <<< "$GATE_KNOWN_SCENARIOS"
fi

# _gate_validate_scenarios <known_csv> <registered_csv> <name...> — classify a bad scenario
# selection into a DISTINCT exit code per class (Design Decision rev3 #5), so callers (and
# sub-project 1's exit-code map) can tell them apart instead of collapsing everything into one
# generic failure:
#   2  'upgrade' selected, or an unknown name          -> config error (bad input from the caller)
#   3  known name with no registered GATE_SCENARIOS fn -> engine/setup fault (a scenario that
#                                                          SHOULD run but can't — its scenario file
#                                                          didn't source)
#   0  every requested name is known and registered
_gate_validate_scenarios() {
    local known="$1" registered="$2"; shift 2; local n
    for n in "$@"; do
        [[ "$n" == "upgrade" ]] && { echo "ERROR: 'upgrade' is not a gate scenario; run: fbt gate upgrade -p <profile> --old-bin <p> --new-bin <p> --target-ver <v>" >&2; return 2; }
        [[ " $known " == *" $n "* ]]      || { echo "ERROR: unknown scenario '$n'" >&2; return 2; }
        [[ " $registered " == *" $n "* ]] || { echo "ERROR: scenario '$n' selected but not registered" >&2; return 3; }
    done
    return 0
}

# Validate every requested name before doing anything else — the registered set is the keys of
# GATE_SCENARIOS (populated by the conditional-source loop above), so this also catches a known
# name whose scripts/scenarios/scenario_<name>.sh didn't source. gate.sh exits with whatever code
# the validator returns; a non-zero rc aborts here, before --dry-run or any chain is touched.
_gate_validate_scenarios "$GATE_KNOWN_SCENARIOS" "${!GATE_SCENARIOS[*]}" "${scenario_list[@]}"

if [[ "$DRY_RUN" == 1 ]]; then
    echo "== gate dry-run =="
    echo "profile: $profile_name"
    # The workspace belongs in the plan: it is where the cluster, the evidence and failures.jsonl
    # will land, and a reader checking a plan before spending a real bring-up needs to see it.
    echo "workspace: $CLUSTER_OUTDIR"
    for name in "${scenario_list[@]}"; do
        echo "scenario: $name"
    done
    echo "stateroot: runtime multi-node discovery under <outdir>/127.0.0.1 (_discover_stateroot_urls), fed to _run_stateroot_oracle"
    exit 0
fi

# ---------------------------------------------------------------------------
# Real-run — needs live chain. Never reached from --dry-run.
# ---------------------------------------------------------------------------

APPLY_PROFILE="$SCRIPT_DIR/apply_profile.sh"
# Every failure from here down names its own outcome. Without event_set_outcome the protocol's
# fallback maps any non-zero exit to engine_error, i.e. exit 40 "fbt has a bug" -- so a chain that
# would not come up, a test machine missing the sibling skill, and a genuine fbt defect all
# reported the same code. Observed end to end: a machine with no cluster_up.sh installed reported
# 40 instead of 30.
[[ -f "$APPLY_PROFILE" ]] || {
    event_set_outcome infra_error
    echo "ERROR: apply_profile.sh not found at $APPLY_PROFILE" >&2
    exit 1
}

echo ">> [1/4] apply_profile (needs live chain): bringing up cluster for $profile_name"
# A cluster that will not come up is an infrastructure condition (spec section 9), which is a
# different instruction to the operator than "file a bug". Under set -e this call used to abort
# the script with apply_profile's own status and no outcome at all.
event_set_outcome infra_error
bash "$APPLY_PROFILE" -p "$PROFILE_PATH" -o "$CLUSTER_OUTDIR"

CLUSTER_OUTDIR_ABS="$(cd "$CLUSTER_OUTDIR" && pwd)"
NODE_DIR="$CLUSTER_OUTDIR_ABS/127.0.0.1"

# RPC URL: derive from node0's FINAL config.ini via _primary_web3_url, not from the profile's own
# [config_ini_override] value — the profile only names the port apply_profile.sh would have
# written BEFORE any host WEB3_BASE override, so reading it directly here silently probed the
# wrong port whenever WEB3_BASE overrode the profile (Design Decision rev3 #2). Reusing
# profile_lib.sh here is a documented assumption that the profile already parsed successfully once
# by apply_profile.sh above — verified only against a live chain, not by this task's own
# (dry-run-only) tests.
source "$SCRIPT_DIR/profile_lib.sh"
source "$SCRIPT_DIR/oracle_lib.sh"
profile_load "$PROFILE_PATH"
RPC_URL="$(_primary_web3_url "$NODE_DIR")" || {
    event_set_outcome infra_error   # no reachable RPC: the machine, not the chain under test
    echo "ERROR: gate: could not derive the primary Web3 RPC URL from $NODE_DIR/node0/config.ini" >&2
    exit 1
}

# Task 13: local defect sink. failures_lib.sh is pure-local (no network — see its own header),
# so sourcing it here does not add a cloud dependency to this real-run path; only
# report_defects.sh (invoked separately, by the model layer) talks to the network. Failures land
# next to the cluster's own node directories so they travel with the rest of that run's evidence.
source "$SCRIPT_DIR/failures_lib.sh"
FAILURES_OUTDIR="$CLUSTER_OUTDIR_ABS"

# Discover live node PIDs from the cluster layout that cluster_up.sh (sibling
# fisco-bcos-testing skill, invoked by apply_profile.sh) produces. Each node's start.sh
# launches its fisco-bcos binary as `${SHELL_FOLDER}/../fisco-bcos ...` where SHELL_FOLDER is
# the node's own absolute dir under NODE_DIR — so every live node process's command line
# contains the NODE_DIR path, and `pgrep -f` against it finds them all. This is a documented
# assumption about that process-launch layout, verified only against a live chain — CRITICAL
# #1/#2 fix: unlike the old "background the oracle scripts, kill+wait at teardown" model, PID
# discovery happens once, up front, and feeds bounded one-shot oracle calls below instead.
mapfile -t node_pids < <(pgrep -f "$NODE_DIR/" 2>/dev/null || true)
if [[ ${#node_pids[@]} -eq 0 ]]; then
    event_set_outcome infra_error   # nothing is running: there is no chain to judge
    echo "ERROR: could not discover any live fisco-bcos node PIDs under $NODE_DIR — apply_profile.sh may not have brought up a chain, or the cluster_up.sh process-launch layout has changed. Real-run requires a live chain; refusing to silently continue with no crash-oracle PIDs." >&2
    exit 1
fi
echo ">> discovered node PIDs: ${node_pids[*]}"

# rpc_current_height — print the current block height as decimal, or empty string on failure.
# Duplicates oracle_liveness.sh's private rpc_block_number rather than sourcing it, to keep
# this orchestrator from depending on that script's internal (non-interface) function names.
rpc_current_height() {
    local resp hex
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$RPC_URL" 2>/dev/null)" || { echo ""; return; }
    hex="$(printf '%s' "$resp" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    [[ -z "$hex" ]] && { echo ""; return; }
    printf '%d\n' "$hex"
}

# run_oracles_once <phase-label> — one bounded pass of all three oracles for the given phase,
# aggregating their real exit codes. CRITICAL #1/#2 fix, restated: every oracle invocation
# below is a single command that runs to completion and returns its own exit status — there is
# no persistent `while true` background process and therefore no teardown `kill` + `wait`=143
# misreport, and no zero-arg invocation that would exit 2 before ever checking anything.
#
# Task 13: whenever an oracle trips, record it into <FAILURES_OUTDIR>/failures.jsonl via
# failures_append (scripts/failures_lib.sh) — profile/scenario/oracle/severity/desc/evidence, so
# a gate FAIL always leaves a local defect row behind even with no cloud auth available. This
# call is local-file-only (see failures_lib.sh's own header); nothing here talks to the network —
# that split is the whole point of Task 13's architecture. The `scenario` value passed to
# failures_append is `_gate_scenario_label "$phase"`, NOT the raw phase label: the phase is
# "baseline" or "after:<scenario>", and report_defects.sh maps `scenario` straight into 场景族, a
# singleSelect column whose option set does not include "after:<x>" strings — only the bare
# scenario family names (plus "baseline" itself, which is a valid option).
run_oracles_once() {
    local phase="$1" rc=0 height scenario_label
    scenario_label="$(_gate_scenario_label "$phase")"
    echo ">> oracle check ($phase): crash"
    if ! bash "$SCRIPT_DIR/oracle_crash.sh" --once "${node_pids[@]}"; then
        rc=1
        failures_append "$FAILURES_OUTDIR" "$profile_name" "$scenario_label" "crash" "高" \
            "oracle_crash tripped during $phase" "bash $SCRIPT_DIR/gate.sh -p $PROFILE_PATH" \
            "$NODE_DIR" "${PROFILE_GENESIS[compatibility_version]:-unknown}"
    fi
    echo ">> oracle check ($phase): liveness"
    if ! bash "$SCRIPT_DIR/oracle_liveness.sh" -r "$RPC_URL"; then
        rc=1
        failures_append "$FAILURES_OUTDIR" "$profile_name" "$scenario_label" "halt" "高" \
            "oracle_liveness tripped during $phase" "bash $SCRIPT_DIR/gate.sh -p $PROFILE_PATH" \
            "$NODE_DIR" "${PROFILE_GENESIS[compatibility_version]:-unknown}"
    fi
    height="$(rpc_current_height)"
    if [[ -z "$height" ]]; then
        echo "ERROR: could not read block height from $RPC_URL for stateroot oracle ($phase)" >&2
        rc=1
    else
        echo ">> oracle check ($phase): stateroot @ $height (multi-node discovery under $NODE_DIR)"
        local sr_rc=0
        _run_stateroot_oracle "$height" "$NODE_DIR" "${RG_FUZZ_STATEROOT_URLS:-}" || sr_rc=$?
        if [[ "$sr_rc" == 3 ]]; then
            echo "ERROR: stateroot ($phase): <2 node RPCs discovered under $NODE_DIR" >&2
            rc=1
        elif [[ "$sr_rc" == 1 ]]; then
            rc=1
            failures_append "$FAILURES_OUTDIR" "$profile_name" "$scenario_label" "state-mismatch" "高" \
                "oracle_stateroot tripped during $phase @ height $height" \
                "bash $SCRIPT_DIR/gate.sh -p $PROFILE_PATH" \
                "$NODE_DIR" "${PROFILE_GENESIS[compatibility_version]:-unknown}"
        fi
    fi
    return $rc
}

echo ">> [2/4] baseline oracle check (needs live chain)"
oracle_tripped=0
run_oracles_once "baseline" || oracle_tripped=1

echo ">> [3/4] running scenarios: ${scenario_list[*]}"
scenario_failed=0

# _gate_validate_scenarios above already guaranteed every name in scenario_list is both known
# and registered, so there is no unregistered-name SKIP branch here.
for name in "${scenario_list[@]}"; do
    fn="${GATE_SCENARIOS[$name]}"
    echo "-- running scenario: $name"
    if "$fn"; then
        echo "-- scenario '$name' PASSED"
    else
        echo "-- scenario '$name' FAILED"
        scenario_failed=1
    fi
    run_oracles_once "after:$name" || oracle_tripped=1
done

echo ">> [4/4] tearing down cluster (needs live chain)"
bash "$NODE_DIR/stop_all.sh" || true

if [[ "$oracle_tripped" == 1 || "$scenario_failed" == 1 ]]; then
    # THE verdict this whole script exists to produce: the chain failed the gate (10), which is an
    # answer about the chain, not a fault in the harness (40).
    event_set_outcome gate_fail
    echo "GATE: FAIL (oracle_tripped=$oracle_tripped scenario_failed=$scenario_failed)"
    exit 1
fi
event_set_outcome pass
echo "GATE: PASS"
