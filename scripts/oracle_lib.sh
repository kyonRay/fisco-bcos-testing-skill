#!/usr/bin/env bash
# oracle_lib.sh — pure decision functions for the three release-gate oracles
# (crash / consensus-halt / state-mismatch). Source this file; do not execute
# directly. No IO here — see oracle_crash.sh / oracle_liveness.sh /
# oracle_stateroot.sh for the RPC/process-polling wrappers that feed these.
set -euo pipefail

# Requires bash 4+ (matches profile_lib.sh's guard; this file doesn't use
# associative arrays today, but keeps the same floor as the rest of scripts/
# so a stray macOS bash 3.2 fails clearly instead of a cryptic parse error).
if (( BASH_VERSINFO[0] < 4 )); then
    echo "oracle_lib.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    return 1 2>/dev/null || exit 1
fi

# oracle_liveness_decide <prev_height> <cur_height> <elapsed_s> <has_pending>
# Halt (return 1) when there is pending work, the stall threshold has been
# exceeded, and the height has not advanced. Threshold defaults to 30s,
# overridable via RG_STALL_SEC.
oracle_liveness_decide() {
    local prev="$1" cur="$2" elapsed="$3" has_pending="$4"
    local threshold="${RG_STALL_SEC:-30}"
    if (( has_pending == 1 && elapsed > threshold && cur <= prev )); then
        return 1
    fi
    return 0
}

# oracle_fork_decide <height_a> <hash_a> <height_b> <hash_b>
# Fork (return 1) when two observations report the same height with
# different block hashes.
oracle_fork_decide() {
    local height_a="$1" hash_a="$2" height_b="$3" hash_b="$4"
    if [[ "$height_a" == "$height_b" && "$hash_a" != "$hash_b" ]]; then
        return 1
    fi
    return 0
}

# oracle_stateroot_decide <root...> — variadic. Diverge (return 1) when any
# argument differs from the first.
oracle_stateroot_decide() {
    local first="$1"
    shift
    local root
    for root in "$@"; do
        if [[ "$root" != "$first" ]]; then
            return 1
        fi
    done
    return 0
}
