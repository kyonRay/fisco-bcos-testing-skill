#!/usr/bin/env bash
# gate_upgrade.sh — executable entry point for the T0-T8 version-upgrade timeline.
#
# WHY THIS FILE EXISTS: the upgrade timeline lives in scenario_upgrade.sh as a shell FUNCTION,
# scenario_upgrade_run, and a function cannot be exec'd. The host starts every engine command as a
# subprocess of a file path, so without a file there is no way to run the upgrade under the same
# process group, environment stripping, deadline and event protocol as everything else. Driving it
# by asking a user to `source` the scenario file and call the function by hand is exactly the
# out-of-band path this tool set out to remove.
#
# It is deliberately NOT a member of GATE_KNOWN_SCENARIOS: gate.sh's dispatch loop calls every
# registered scenario with no arguments, and this one needs four. Selecting `upgrade` in
# --scenarios is a usage error that points here.
#
# Usage:
#   gate_upgrade.sh -p <profile> --old-bin <path> --new-bin <path> --target-ver <version>
#                   [-o <outdir>] [--dry-run]
#
# Flags:
#   -p <profile>        profile file to reproduce (required)
#   --old-bin <path>    the binary the chain starts on: the T0 baseline (required)
#   --new-bin <path>    the release candidate rolled in during T2-T4 (required)
#   --target-ver <ver>  compatibility_version the T5 bump moves to (required)
#   -o <outdir>         cluster workspace; host-provided (default ./nodes-release-gate-upgrade)
#   --dry-run           print the resolved plan, touch no chain
#   -h                  this help
#
# Exit codes follow the repo convention the event protocol maps from: 0 clean, 2 usage error,
# non-zero otherwise. A gate verdict is reported through event_set_outcome, not inferred from the
# code, because "the upgrade broke the chain" and "the script itself fell over" are both non-zero
# and must not be confused.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "gate_upgrade.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Armed before parsing, so a missing --old-bin still terminates with an event (design doc §8).
source "$SCRIPT_DIR/event_lib.sh"
event_begin_command gate_upgrade.sh

PROFILE_PATH=""
OLD_BIN=""
NEW_BIN=""
TARGET_VER=""
OUTDIR="./nodes-release-gate-upgrade"
DRY_RUN=0

# Long flags first: getopts only knows short ones.
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --old-bin|--new-bin|--target-ver)
            # Reading $2 unconditionally under `set -u` would abort with a raw "unbound variable"
            # instead of a usage error naming the flag.
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value. -h for help." >&2; exit 2; }
            case "$1" in
                --old-bin) OLD_BIN="$2" ;;
                --new-bin) NEW_BIN="$2" ;;
                --target-ver) TARGET_VER="$2" ;;
            esac
            shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

while getopts "p:o:h" opt; do
    case "$opt" in
        p) PROFILE_PATH="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done

for req in PROFILE_PATH:-p OLD_BIN:--old-bin NEW_BIN:--new-bin TARGET_VER:--target-ver; do
    var="${req%%:*}"; flag="${req##*:}"
    [[ -n "${!var}" ]] || { echo "ERROR: $flag is required. -h for help." >&2; exit 2; }
done
[[ -f "$PROFILE_PATH" ]] || { echo "ERROR: profile not found: $PROFILE_PATH" >&2; exit 2; }
for req in OLD_BIN:--old-bin NEW_BIN:--new-bin; do
    var="${req%%:*}"; flag="${req##*:}"
    # A path that is configured but points nowhere is an infrastructure problem, not a usage one,
    # so it is reported as such rather than lumped in with the missing-flag cases above.
    if [[ ! -f "${!var}" ]]; then
        event_set_outcome infra_error
        echo "ERROR: $flag: no such file: ${!var}" >&2
        exit 1
    fi
done

emit_event upgrade_plan profile "$PROFILE_PATH" old_bin "$OLD_BIN" new_bin "$NEW_BIN" \
    target_ver "$TARGET_VER" outdir "$OUTDIR"

if (( DRY_RUN )); then
    echo "DRY: gate_upgrade: profile=$PROFILE_PATH"
    echo "DRY: gate_upgrade: T0 baseline binary=$OLD_BIN"
    echo "DRY: gate_upgrade: rolling upgrade target binary=$NEW_BIN"
    echo "DRY: gate_upgrade: T5 compatibility_version bump -> $TARGET_VER"
    echo "DRY: gate_upgrade: cluster workspace=$OUTDIR"
    echo "DRY: gate_upgrade: would call scenario_upgrade_run <outdir> <old_bin> <new_bin> <target_ver>"
    exit 0
fi

source "$SCRIPT_DIR/scenarios/scenario_upgrade.sh"

mkdir -p "$OUTDIR"
OUTDIR_ABS="$(cd "$OUTDIR" && pwd)"

set +e
scenario_upgrade_run "$OUTDIR_ABS" "$OLD_BIN" "$NEW_BIN" "$TARGET_VER"
rc=$?
set -e

# A non-zero return here is the upgrade timeline's own verdict on the chain, which is a gate
# failure -- not an engine fault. Leaving it to the exit-code fallback would report engine_error
# and the host would raise 40 ("fbt has a bug") for a chain that genuinely broke on upgrade.
if (( rc == 0 )); then
    event_set_outcome pass
    echo "GATE UPGRADE: PASS"
else
    event_set_outcome gate_fail
    echo "GATE UPGRADE: FAIL (scenario_upgrade_run returned $rc)" >&2
fi
exit "$rc"
