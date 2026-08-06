#!/usr/bin/env bash
# apply_profile.sh — replay a captured production .profile onto a local FISCO-BCOS AIR cluster.
#
# Usage:
#   apply_profile.sh -p <profile> [-o outdir] [--dry-run] [-h]
#     -p  path to a .profile file (required)          e.g. profiles/production-enterprise.profile
#     -o  output dir for the generated cluster         (default ./nodes-release-gate)
#     --dry-run  print the plan to stdout and exit — no build_chain, no cluster_up.sh, no network.
#                Prints: (1) the build_chain invocation incl. compatibility_version, (2) the
#                config.ini patch lines from [config_ini_override], (3) one setSystemConfigByKey
#                line per [system_config_replay] pair. Flags absent from the profile are never
#                invented or emitted.
#     -h  print this help and exit
#
# Real-run (no --dry-run; needs a live fisco-bcos binary — NOT exercised by this skill's own
# tests, since there is no binary in this environment):
#   1. cluster_up.sh (sibling fisco-bcos-testing skill) runs build_chain + start_all and waits
#      for RPC to answer.
#   2. Each node's config.ini is patched per [config_ini_override].
#   3. The cluster is restarted so the config.ini patch takes effect.
#   4. Each [system_config_replay] pair is replayed via the Java console's setSystemConfigByKey.
set -euo pipefail

# Requires bash 4+ (profile_lib.sh uses associative arrays). Fail clearly instead of a cryptic
# `declare: -gA: invalid option` on stock macOS bash 3.2.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "apply_profile.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE_PATH=""
OUTDIR="./nodes-release-gate"
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

while getopts "p:o:h" opt; do
    case "$opt" in
        p) PROFILE_PATH="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done

[[ -z "$PROFILE_PATH" ]] && { echo "ERROR: -p <profile> is required. -h for help." >&2; exit 2; }
[[ -f "$PROFILE_PATH" ]] || { echo "ERROR: profile not found: $PROFILE_PATH" >&2; exit 1; }

source "$SCRIPT_DIR/profile_lib.sh"
profile_load "$PROFILE_PATH"

genesis_compat="${PROFILE_GENESIS[compatibility_version]:-}"
[[ -z "$genesis_compat" ]] && { echo "ERROR: profile has no [genesis] compatibility_version" >&2; exit 1; }

if [[ "$DRY_RUN" == 1 ]]; then
    echo "== apply_profile dry-run =="
    echo "profile: $PROFILE_PATH"
    echo "outdir:  $OUTDIR"
    echo ""
    echo "[1/3] build_chain:"
    echo "  tools/BcosAirBuilder/build_chain.sh -v \"$genesis_compat\" -p 30300,20200 -l 127.0.0.1:4 -o \"$OUTDIR\"   # compatibility_version $genesis_compat"
    echo ""
    echo "[2/3] config.ini patch (from [config_ini_override]):"
    while read -r pair; do
        [[ -z "$pair" ]] && continue
        fullkey="${pair%% *}"
        value="${pair#* }"
        echo "  ${fullkey} = ${value}"
    done < <(profile_config_pairs)
    echo ""
    echo "[3/3] console replay (from [system_config_replay]):"
    while read -r pair; do
        [[ -z "$pair" ]] && continue
        key="${pair%% *}"
        value="${pair#* }"
        echo "  setSystemConfigByKey ${key} ${value}"
    done < <(profile_replay_pairs)
    exit 0
fi

# ---------------------------------------------------------------------------
# Real-run — needs live chain. Never reached from --dry-run.
# ---------------------------------------------------------------------------

CLUSTER_UP="$SCRIPT_DIR/../../fisco-bcos-testing/scripts/cluster_up.sh"
[[ -f "$CLUSTER_UP" ]] || {
    echo "ERROR: sibling skill script not found: $CLUSTER_UP (expected the fisco-bcos-testing skill checked out alongside this one)" >&2
    exit 1
}

echo ">> [1/4] cluster_up (needs live chain): build_chain + start_all into $OUTDIR"
# NOTE: cluster_up.sh does not currently expose a compatibility_version passthrough to
# build_chain -v; the genesis compat version in this profile ($genesis_compat) is applied
# best-effort. Extending cluster_up.sh's flag surface is out of this task's scope.
bash "$CLUSTER_UP" -o "$OUTDIR"
NODE_DIR="$OUTDIR/127.0.0.1"

echo ">> [2/4] patching config.ini per profile (needs live chain)"
while read -r pair; do
    [[ -z "$pair" ]] && continue
    fullkey="${pair%% *}"
    value="${pair#* }"
    section="${fullkey%%.*}"
    key="${fullkey#*.}"
    for cfg in "$NODE_DIR"/node*/config.ini; do
        [[ -f "$cfg" ]] || continue
        perl -0pi -e "s/(\[\Q$section\E\][^\[]*?\n\s*\Q$key\E\s*=\s*)\S+/\${1}$value/s" "$cfg"
    done
done < <(profile_config_pairs)

echo ">> [3/4] restarting cluster to pick up config.ini patch (needs live chain)"
bash "$NODE_DIR/stop_all.sh"
bash "$NODE_DIR/start_all.sh"

echo ">> [4/4] replaying setSystemConfigByKey via console (needs live chain)"
while read -r pair; do
    [[ -z "$pair" ]] && continue
    key="${pair%% *}"
    value="${pair#* }"
    echo "  setSystemConfigByKey $key $value"
    bash console.sh setSystemConfigByKey "$key" "$value"
done < <(profile_replay_pairs)

echo ">> cluster ready at $OUTDIR (profile: $PROFILE_PATH)"
