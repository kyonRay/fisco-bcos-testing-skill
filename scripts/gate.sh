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
#                names against GATE_KNOWN_SCENARIOS, and exit — no chain, no oracles, no
#                scenario execution. An unrecognized scenario name is an error (exit 1).
#     -h  print this help and exit
#
# Scenario names are validated declaratively against GATE_KNOWN_SCENARIOS, independent of
# whether the corresponding scenario function has actually been implemented yet (Tasks 7-10
# add scripts/scenarios/scenario_<name>.sh one at a time; each registers into the
# GATE_SCENARIOS[name]=function associative array by being conditionally sourced below).
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
#   3. Each requested scenario name is looked up in GATE_SCENARIOS and run in turn; a name
#      with no registered function (i.e. its Task 7-10 scenario file hasn't been added yet,
#      or simply wasn't sourced) is reported as a skip, not a crash. 'upgrade' is ALSO skipped
#      here (not run, not failed) even once registered: its scenario_upgrade_run needs
#      <outdir> <old_bin> <new_bin> <target_ver>, which this bare-dispatch loop cannot supply —
#      run it directly (source scripts/scenarios/scenario_upgrade.sh; call scenario_upgrade_run
#      yourself, see SKILL.md / references/upgrade-path.md). This keeps the DEFAULT scenario
#      sweep (GATE_KNOWN_SCENARIOS = all four names) able to reach GATE: PASS on a healthy chain.
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

# Declarative list of valid scenario names, used by --dry-run validation. This does NOT depend
# on scripts/scenarios/*.sh having been written yet — Tasks 7-10 add those files one at a time,
# and this list already knows all four names up front.
GATE_KNOWN_SCENARIOS="ut dual_rpc malformed jsd upgrade"

# GATE_SCENARIOS_NEEDS_ARGS: scenario names whose registered function cannot be dispatched bare
# ("$fn" with zero arguments) the way every other scenario is — today only 'upgrade'
# (scenario_upgrade_run <outdir> <old_bin> <new_bin> <target_ver>; see scripts/scenarios/
# scenario_upgrade.sh's own header and references/upgrade-path.md). A name in this set is a valid
# GATE_KNOWN_SCENARIOS entry (validated by --dry-run, reachable via a direct scenario_upgrade_run
# call — see SKILL.md) but is SKIPped, not run, by the real-run bare-dispatch loop below, and is
# flagged in --dry-run output too so this is visible without a live chain. Declared up front (pure
# data, no live-chain dependency) so both --dry-run and the real-run loop read the same set.
# Without this, the default (`--scenarios` omitted) sweep — the documented canonical
# `gate.sh -p <profile>` command — always included 'upgrade', which failed its missing-arg check
# every time and turned GATE: PASS into GATE: FAIL even on a healthy chain.
declare -A GATE_SCENARIOS_NEEDS_ARGS=([upgrade]=1)

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

while getopts "p:h" opt; do
    case "$opt" in
        p) PROFILE_PATH="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done

[[ -z "$PROFILE_PATH" ]] && { echo "ERROR: -p <profile> is required. -h for help." >&2; exit 2; }
[[ -f "$PROFILE_PATH" ]] || { echo "ERROR: profile not found: $PROFILE_PATH" >&2; exit 1; }

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

# Validate every requested name against the declarative known-scenario list before doing
# anything else — this check does not depend on GATE_SCENARIOS having a registered function
# for the name, only on the name being a recognized one.
for name in "${scenario_list[@]}"; do
    if [[ ! " $GATE_KNOWN_SCENARIOS " == *" $name "* ]]; then
        echo "ERROR: unknown scenario '$name' — known scenarios: $GATE_KNOWN_SCENARIOS" >&2
        exit 1
    fi
done

if [[ "$DRY_RUN" == 1 ]]; then
    echo "== gate dry-run =="
    echo "profile: $profile_name"
    for name in "${scenario_list[@]}"; do
        echo "scenario: $name"
        if [[ -n "${GATE_SCENARIOS_NEEDS_ARGS[$name]:-}" ]]; then
            echo "  needs-args: $name is SKIPped by the default bare-dispatch loop (requires old/new binaries + target version) — run it directly, see SKILL.md"
        fi
    done
    echo "stateroot: runtime multi-node discovery under <outdir>/127.0.0.1 (_discover_stateroot_urls), fed to _run_stateroot_oracle"
    exit 0
fi

# ---------------------------------------------------------------------------
# Real-run — needs live chain. Never reached from --dry-run.
# ---------------------------------------------------------------------------

APPLY_PROFILE="$SCRIPT_DIR/apply_profile.sh"
[[ -f "$APPLY_PROFILE" ]] || { echo "ERROR: apply_profile.sh not found at $APPLY_PROFILE" >&2; exit 1; }

CLUSTER_OUTDIR="./nodes-release-gate"

echo ">> [1/4] apply_profile (needs live chain): bringing up cluster for $profile_name"
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

# GATE_SCENARIOS_NEEDS_ARGS is declared up front, alongside GATE_KNOWN_SCENARIOS — see that
# declaration's comment for what this set means and why it exists.
for name in "${scenario_list[@]}"; do
    fn="${GATE_SCENARIOS[$name]:-}"
    if [[ -z "$fn" ]]; then
        echo "SKIP: scenario '$name' has no registered function (not implemented yet)"
        continue
    fi
    if [[ -n "${GATE_SCENARIOS_NEEDS_ARGS[$name]:-}" ]]; then
        echo "SKIP: $name requires old/new binaries + target version — run it directly, see SKILL.md (source scripts/scenarios/scenario_$name.sh; ${fn} <outdir> <old_bin> <new_bin> <target_ver>)"
        continue
    fi
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
    echo "GATE: FAIL (oracle_tripped=$oracle_tripped scenario_failed=$scenario_failed)"
    exit 1
fi
echo "GATE: PASS"
