#!/usr/bin/env bash
# cluster_down.sh — stop the nodes of one cluster workspace.
#
# WHY THIS FILE EXISTS: teardown is stop_all.sh, which lives in the sibling fisco-bcos-testing
# skill and knows nothing about the fd 3 event protocol. A host that exec'd it directly would get
# a subprocess that exits without a command_finished, which the protocol defines as "the engine
# died unexpectedly" — reporting fbt's own bug (40) for a teardown that worked. This wrapper is
# the engine command; stop_all.sh is what it calls.
#
# It is deliberately IDEMPOTENT. `fbt cluster down` runs on clusters that are half dead, fully
# dead, or in an unknown state — that is when someone reaches for it — so "the nodes were already
# gone" is a success, not a failure. A teardown that errors on an already-stopped cluster leaves
# the registry entry standing and the ports reserved forever.
#
# Usage:
#   cluster_down.sh -o <cluster_dir> [--dry-run]
#
# Flags:
#   -o <dir>    the cluster workspace to stop (required)
#   --dry-run   print the plan, stop nothing
#   -h          this help
#
# Exit codes: 0 clean, 2 usage error. A missing stop_all.sh is reported through
# event_set_outcome infra_error, because the machine is missing a dependency rather than the user
# having typed something wrong.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "cluster_down.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Armed before parsing, so a missing -o still terminates with an event (design doc §8).
source "$SCRIPT_DIR/event_lib.sh"
event_begin_command cluster_down.sh

OUTDIR=""
DRY_RUN=0

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        *) args+=("$1"); shift ;;
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

[[ -n "$OUTDIR" ]] || { echo "ERROR: -o <cluster_dir> is required. -h for help." >&2; exit 2; }

# Same resolution order as apply_profile.sh's _resolve_engine_script: an installed libexec layout
# has no sibling checkout, so $FBT_ENGINE_SCRIPTS has to come first.
_resolve_engine_script() {
    local n="$1" c
    for c in "${FBT_ENGINE_SCRIPTS:-}" "$SCRIPT_DIR" "$SCRIPT_DIR/../../fisco-bcos-testing/scripts"; do
        [[ -n "$c" && -f "$c/$n" ]] && { echo "$c/$n"; return 0; }
    done
    return 1
}

if (( DRY_RUN )); then
    echo "DRY: cluster_down: workspace=$OUTDIR"
    echo "DRY: cluster_down: would run stop_all.sh against every node directory under it"
    exit 0
fi

# A workspace that is not there is already stopped. Erroring here would strand the reservation of
# a cluster whose directory somebody deleted by hand.
if [[ ! -d "$OUTDIR" ]]; then
    emit_event cluster_down_skipped reason "workspace_absent" outdir "$OUTDIR"
    echo "cluster_down: $OUTDIR does not exist; nothing to stop"
    exit 0
fi

STOP_ALL="$(_resolve_engine_script stop_all.sh)" || {
    event_set_outcome infra_error
    echo "ERROR: stop_all.sh not found (tried \$FBT_ENGINE_SCRIPTS, $SCRIPT_DIR, sibling fisco-bcos-testing/scripts)" >&2
    exit 1
}

emit_event cluster_down_started outdir "$OUTDIR"

# stop_all.sh returns non-zero when it finds nothing to stop, which for this command is the
# expected steady state rather than a failure — see the idempotence note in the header.
set +e
bash "$STOP_ALL" "$OUTDIR"
rc=$?
set -e

emit_event cluster_down_finished outdir "$OUTDIR" stop_all_exit "#$rc"
if (( rc != 0 )); then
    echo "cluster_down: stop_all.sh exited $rc (already stopped, or some nodes were gone)" >&2
fi
echo "cluster_down: $OUTDIR stopped"
exit 0
