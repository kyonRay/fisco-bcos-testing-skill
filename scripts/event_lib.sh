#!/usr/bin/env bash
# event_lib.sh — the engine side of the fd 3 event protocol (design doc §8).
#
# The host opens fd 3 as a pipe and reads one JSON object per line. Everything here is a no-op
# when fd 3 is not open, so every script that sources this file still runs standalone under a
# plain shell — that is a hard requirement of §4, not a convenience.
#
# Three rules the design doc makes non-negotiable, and which this file exists to enforce:
#
#   1. Events are FLAT. `{"schema_version":"1.0.0","ev":"scenario_started","name":"malformed"}`,
#      never a nested "payload" object. The host rejects a top-level payload key outright,
#      because a silent second layer of nesting would make every field lookup downstream return
#      nothing.
#   2. Every directly-launched engine command emits EXACTLY ONE `command_finished`, carrying the
#      authoritative `outcome`. The host maps the process's exit code from that field alone; it
#      does not guess from whatever `error` events came before.
#   3. The EXIT trap is installed BEFORE argument and profile parsing. A usage error that exits at
#      line 20 must still produce a terminating event, or the host sees a subprocess that died
#      without finishing and reports its own bug (40) for what is really a config error (20).
#
# Free text does not belong in events (§8): error detail, repro strings and log fragments go to
# failures.jsonl or an evidence file, and the event carries the PATH. Values here are therefore
# identifiers and paths — but paths can legitimately contain quotes and backslashes, so they are
# still escaped properly rather than assumed safe.
#
# Usage:
#   source "$SCRIPT_DIR/event_lib.sh"
#   event_begin_command gate.sh          # emits command_started, installs the EXIT trap
#   emit_event scenario_started name malformed
#   emit_event fuzz_batch idx '#7'       # a '#' prefix emits the value as a raw JSON number
#   event_set_outcome gate_fail          # before exiting with a gate verdict
#
# This file is sourced into callers that already run under `set -euo pipefail`; it does not set
# shell options of its own, because doing so would change the sourcing script's behaviour.

EVENT_SCHEMA_VERSION="1.0.0"

# Is fd 3 open? Probed once, here, rather than on every emit. `printf ''` writes nothing, so the
# probe cannot corrupt a stream that IS open.
if { printf '' >&3; } 2>/dev/null; then
    EVENT_FD_OPEN=1
else
    EVENT_FD_OPEN=0
fi

EVENT_CMD=""
EVENT_OUTCOME=""
EVENT_FINISHED=0
EVENT_SIGNAL=""

# _json_escape <string> — escape a bash string for a JSON string literal.
#
# Backslash MUST be replaced first: doing quotes first would then escape the backslashes this step
# introduces, turning `"` into `\\"` and producing invalid JSON. Control characters below 0x20 are
# not representable raw in JSON, so they become \u00XX.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    # Anything else below 0x20 (and 0x7f) is rare enough to be worth a per-character pass only
    # when one is actually present.
    if [[ "$s" == *[$'\x01'-$'\x1f\x7f']* ]]; then
        local out="" i c
        for (( i = 0; i < ${#s}; i++ )); do
            c="${s:i:1}"
            if [[ "$c" == [$'\x01'-$'\x1f\x7f'] ]]; then
                printf -v c '\\u%04x' "'$c"
            fi
            out+="$c"
        done
        s="$out"
    fi
    printf '%s' "$s"
}

# emit_event <ev> [key value]... — write one flat JSON object to fd 3.
#
# A value beginning with '#' is emitted RAW, for numbers and booleans: `idx '#7'` gives
# `"idx":7`, not `"idx":"7"`. Without it every number would arrive as a string and the host's
# UseNumber decoding — the whole reason block heights keep their precision — would be pointless.
# Paths and identifiers never begin with '#', so the marker cannot collide with a real value.
emit_event() {
    (( EVENT_FD_OPEN )) || return 0
    local ev="$1"; shift
    local line key value
    printf -v line '{"schema_version":"%s","ev":"%s"' "$EVENT_SCHEMA_VERSION" "$(_json_escape "$ev")"
    while (( $# >= 2 )); do
        key="$1"; value="$2"; shift 2
        if [[ "$value" == '#'* ]]; then
            line+=",\"$(_json_escape "$key")\":${value:1}"
        else
            line+=",\"$(_json_escape "$key")\":\"$(_json_escape "$value")\""
        fi
    done
    if (( $# )); then
        # An odd trailing argument means the caller mis-paired its fields. Dropping it silently
        # would ship an event missing a field nobody notices is gone.
        line+=",\"_malformed_trailing_field\":\"$(_json_escape "$1")\""
    fi
    line+='}'
    printf '%s\n' "$line" >&3
}

# event_set_outcome <pass|gate_fail|config_error|infra_error|engine_error>
#
# Call this when the script KNOWS its verdict, before exiting. Without it the EXIT trap falls back
# to mapping the exit code, which cannot tell a gate failure (10) from an engine fault (40) —
# both are just non-zero.
event_set_outcome() { EVENT_OUTCOME="$1"; }

# _event_outcome_for_rc <rc> — the fallback used when the script never set an outcome.
#
# 0 is a pass. 2 is what every script in this repo uses for a usage error, and usage errors are
# configuration problems. Anything else is left as engine_error rather than guessed at: a script
# that means "gate failure" has to say so with event_set_outcome, because silently calling every
# non-zero exit a gate failure would turn a crashed engine into a clean "the chain has a bug"
# verdict.
_event_outcome_for_rc() {
    case "$1" in
        0) printf 'pass' ;;
        2) printf 'config_error' ;;
        *) printf 'engine_error' ;;
    esac
}

# _event_finish <rc> — emit command_finished at most once.
#
# "At most once" is the point: the trap fires on every exit path, and a second event would make
# the host's state machine see two terminations for one command.
_event_finish() {
    (( EVENT_FINISHED )) && return 0
    EVENT_FINISHED=1
    local rc="$1" outcome="$EVENT_OUTCOME"
    [[ -n "$outcome" ]] || outcome="$(_event_outcome_for_rc "$rc")"
    if [[ -n "$EVENT_SIGNAL" ]]; then
        emit_event command_finished cmd "$EVENT_CMD" outcome "$outcome" \
            engine_exit "#$rc" signal "$EVENT_SIGNAL"
    else
        emit_event command_finished cmd "$EVENT_CMD" outcome "$outcome" engine_exit "#$rc"
    fi
}

# _event_on_exit — the EXIT trap. `local rc=$?` must be the first statement, or the assignment
# itself overwrites the status being reported.
_event_on_exit() {
    local rc=$?
    _event_finish "$rc"
}

# _event_on_signal <name> <number> — a signal trap that tells the truth about how the script died.
#
# Bash DOES run the EXIT trap when a script is terminated by a signal it can catch, but `$?` inside
# that trap is the status of the last command that ran, not the signal. Measured before this
# existed: `kill -TERM` produced `{"outcome":"pass","engine_exit":0}` — a killed engine reporting a
# clean pass. Since the host maps its exit code from `outcome` alone, a gate run the host itself
# TERMed on timeout would have come back a PASS. That is the precise false green this whole harness
# exists to prevent, so the signal path gets its own trap: record the signal, report the
# conventional 128+n, then re-raise so the parent still sees the real cause of death.
#
# SIGKILL cannot be caught, so a KILLed engine emits nothing at all — which is exactly the
# "terminated with no command_finished" condition the host reads as an engine that died
# unexpectedly (40).
_event_on_signal() {
    local name="$1" num="$2"
    EVENT_SIGNAL="$name"
    [[ -n "$EVENT_OUTCOME" ]] || EVENT_OUTCOME="engine_error"
    _event_finish "$(( 128 + num ))"
    trap - EXIT "$name"
    kill "-$name" $$
}

# event_begin_command <cmd> — emit command_started and arm the terminating event.
#
# Call it as early as possible: before flag parsing, before profile loading, before any check that
# can exit. Everything after this line is covered; anything before it is not.
event_begin_command() {
    EVENT_CMD="$1"
    EVENT_OUTCOME=""
    EVENT_FINISHED=0
    EVENT_SIGNAL=""
    trap _event_on_exit EXIT
    trap '_event_on_signal TERM 15' TERM
    trap '_event_on_signal INT 2' INT
    trap '_event_on_signal HUP 1' HUP
    emit_event command_started cmd "$EVENT_CMD"
}
