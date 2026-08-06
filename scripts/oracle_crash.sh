#!/usr/bin/env bash
# oracle_crash.sh — crash oracle: detect a dead/aborted node process, plus an
# RPC liveness probe to tell "process is up but hung" apart from "halted but
# alive". Needs a live chain (or at least a live PID) to be meaningful; the
# process-detection half is exercised by the brief's --once real-test below,
# the RPC-probe half is NOT unit-tested by this skill's own tests.
#
# Usage:
#   oracle_crash.sh [-r rpc_url] [-i poll_interval_s] <pid...>
#   oracle_crash.sh --once <pid...>      # bounded check-and-exit, no continuous poll
#     -r  RPC URL to probe                              (default http://127.0.0.1:8545)
#     -i  poll interval in seconds                       (default 2)
#     -h  print this help and exit
#   --once  watch the given PIDs for up to RG_ONCE_WAIT_SEC (default 2s,
#           polled every 0.1s) and exit as soon as a crash is detected, or
#           after the window elapses with none found. This is a single
#           bounded observation, not the continuous supervisory loop below —
#           it exists for scripted one-shot checks where a caller kills a
#           process asynchronously (e.g. in a backgrounded subshell) and
#           needs a deterministic window to observe the death, rather than
#           racing an instantaneous kill -0 against process teardown.
#
# Detects, per PID, exactly two signals (see oracle_crash_check — this is
# the full extent of what it checks, not a summary of a larger mechanism):
#   - process disappearance (kill -0 fails and it's not just a permissions issue)
#   - a core dump file matching core* / core.<pid> in the cwd or /cores (macOS)
# Plus one RPC liveness probe (curl :8545, timeout RG_HANG_SEC default 10s) to
# distinguish "process alive but RPC hung" from "process crashed outright" —
# a hang is reported but is not by itself a crash verdict.
#
# NOT implemented, and not applicable to how this oracle is actually used:
# there is no exit-code/SIGABRT(134) check via shell `wait` status. That only
# works for a PID that is a direct job of *this* shell; in a real gate run
# the node PIDs come from start_all.sh, so this script never has a `wait`-able
# child to inspect. Do not add one on that basis.
#
# Known gap this leaves: a SIGABRT'd-but-unreaped zombie still answers
# `kill -0` (it's not gone yet), and with core dumps disabled (`ulimit -c 0`,
# common in CI/production) there is no core file either — so a real abort can
# slip past both checks here. For that failure mode, an ASan/TSan build (this
# skill's optional hardening layer) is the sharper signal: it aborts loudly
# and synchronously at the faulting instruction rather than relying on this
# oracle to notice the aftermath.
#
# Exit status: non-zero when a crash was detected for any PID.
set -euo pipefail

RPC_URL="http://127.0.0.1:8545"
POLL_INTERVAL=2
ONCE=0

args=()
for arg in "$@"; do
    case "$arg" in
        --once) ONCE=1 ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

while getopts "r:i:h" opt; do
    case "$opt" in
        r) RPC_URL="$OPTARG" ;;
        i) POLL_INTERVAL="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -ge 1 ]] || { echo "ERROR: at least one PID required. -h for help." >&2; exit 2; }

# oracle_crash_check <pid...> — one pass over the given PIDs. Prints a
# CRASH line per dead/aborted PID found; returns non-zero if any were found.
oracle_crash_check() {
    local pid found=0
    for pid in "$@"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "CRASH: pid $pid is gone"
            found=1
            continue
        fi
        # NOTE: these three paths are relative to $PWD (plus the fixed /cores/ on macOS) — this
        # scan only finds a core file when this script happens to run from the node's own dir,
        # which `gate.sh` does not guarantee (it invokes oracle_crash.sh from its own cwd, not
        # from $NODE_DIR). The `kill -0` disappearance check above is cwd-independent and is the
        # load-bearing half of this oracle; the core-dump half below is best-effort on top of it.
        for core in "core.$pid" core /cores/core."$pid"; do
            if [[ -f "$core" ]]; then
                echo "CRASH: core dump found for pid $pid ($core)"
                found=1
            fi
        done
    done
    return "$found"
}

# rpc_liveness_probe — curl getBlockNumber with an RG_HANG_SEC timeout.
# Prints HANG (not by itself a crash) when the node is up but RPC doesn't
# answer in time; returns non-zero on a hang so callers can log it.
rpc_liveness_probe() {
    local hang_sec="${RG_HANG_SEC:-10}"
    if ! curl -sS -m "$hang_sec" -o /dev/null \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$RPC_URL" 2>/dev/null; then
        echo "HANG: RPC $RPC_URL did not answer within ${hang_sec}s"
        return 1
    fi
    return 0
}

if [[ "$ONCE" == 1 ]]; then
    # Poll every 0.1s for RG_ONCE_WAIT_SEC (default 2s). Iteration-counted
    # rather than wall-clock-timed: macOS's BSD `date` has no sub-second
    # precision (%N is a GNU-date-only extension), so a fixed tick count at
    # a known interval is the portable way to bound this window.
    once_wait="${RG_ONCE_WAIT_SEC:-2}"
    ticks=$(( once_wait * 10 ))
    tick=0
    while true; do
        if ! oracle_crash_check "$@"; then
            exit 1
        fi
        tick=$((tick + 1))
        (( tick >= ticks )) && exit 0
        sleep 0.1
    done
fi

while true; do
    if ! oracle_crash_check "$@"; then
        exit 1
    fi
    rpc_liveness_probe || true
    sleep "$POLL_INTERVAL"
done
