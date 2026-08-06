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
#   1. apply_profile.sh brings up the cluster and replays the profile onto it.
#   2. Oracle monitoring (crash / consensus-halt / state-mismatch) starts in the background.
#   3. Each requested scenario name is looked up in GATE_SCENARIOS and run in turn; a name
#      with no registered function (i.e. its Task 7-10 scenario file hasn't been added yet,
#      or simply wasn't sourced) is reported as a skip, not a crash.
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
GATE_KNOWN_SCENARIOS="ut dual_rpc malformed upgrade"

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
        --scenarios) SCENARIOS_RAW="$2"; shift 2 ;;
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
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Real-run — needs live chain. Never reached from --dry-run.
# ---------------------------------------------------------------------------

APPLY_PROFILE="$SCRIPT_DIR/apply_profile.sh"
[[ -f "$APPLY_PROFILE" ]] || { echo "ERROR: apply_profile.sh not found at $APPLY_PROFILE" >&2; exit 1; }

echo ">> [1/4] apply_profile (needs live chain): bringing up cluster for $profile_name"
bash "$APPLY_PROFILE" -p "$PROFILE_PATH"

echo ">> [2/4] starting oracle monitoring in background (needs live chain)"
oracle_pids=()
for oracle in oracle_crash oracle_liveness oracle_stateroot; do
    oracle_script="$SCRIPT_DIR/${oracle}.sh"
    [[ -f "$oracle_script" ]] || continue
    bash "$oracle_script" &
    oracle_pids+=("$!")
done

echo ">> [3/4] running scenarios: ${scenario_list[*]}"
scenario_failed=0
for name in "${scenario_list[@]}"; do
    fn="${GATE_SCENARIOS[$name]:-}"
    if [[ -z "$fn" ]]; then
        echo "SKIP: scenario '$name' has no registered function (not implemented yet)"
        continue
    fi
    echo "-- running scenario: $name"
    if "$fn"; then
        echo "-- scenario '$name' PASSED"
    else
        echo "-- scenario '$name' FAILED"
        scenario_failed=1
    fi
done

echo ">> [4/4] tearing down cluster (needs live chain)"
oracle_tripped=0
for pid in "${oracle_pids[@]+"${oracle_pids[@]}"}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || oracle_tripped=1
done

if [[ "$oracle_tripped" == 1 || "$scenario_failed" == 1 ]]; then
    echo "GATE: FAIL (oracle_tripped=$oracle_tripped scenario_failed=$scenario_failed)"
    exit 1
fi
echo "GATE: PASS"
