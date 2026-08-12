#!/usr/bin/env bash
# tests/event_lib_test.sh — the fd 3 event protocol (design doc §8).
#
# Every case runs event_lib.sh in a real child shell with fd 3 redirected to a file, because the
# things worth testing here — "is fd 3 open", "does the EXIT trap fire", "is there exactly one
# command_finished" — only exist across a process boundary.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh

LIB="$PWD/scripts/event_lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# run_with_fd3 <body> — run body in a child shell with fd 3 captured; echo the captured lines.
run_with_fd3() {
    local body="$1" out="$tmp/events.$RANDOM"
    bash -c "set -euo pipefail; source '$LIB'; $body" 3> "$out" > "$tmp/stdout" 2> "$tmp/stderr" || true
    cat "$out"
}

# run_without_fd3 <body> — same, but fd 3 stays closed: the standalone-bash case.
run_without_fd3() {
    bash -c "set -euo pipefail; source '$LIB'; $1" 2>&1
}

# ---------------------------------------------------------------------------
# Flatness and the envelope.
# ---------------------------------------------------------------------------
line="$(run_with_fd3 'emit_event scenario_started name malformed')"
assert_eq '{"schema_version":"1.0.0","ev":"scenario_started","name":"malformed"}' "$line" \
    "emit_event writes one flat object with schema_version and ev"
assert_not_contains "$line" '"payload"' "no payload wrapper — the host rejects a nested envelope outright"

# ---------------------------------------------------------------------------
# Numbers stay numbers. Without the '#' marker every count would arrive quoted, and the host's
# UseNumber decoding (which exists so block heights keep their precision) would have nothing to do.
# ---------------------------------------------------------------------------
line="$(run_with_fd3 "emit_event fuzz_batch idx '#7' note plain")"
assert_contains "$line" '"idx":7' "a '#' prefix emits a raw JSON number"
assert_contains "$line" '"note":"plain"' "an ordinary value stays a JSON string"

# ---------------------------------------------------------------------------
# Escaping. A .case filename or profile path can legitimately contain a quote or a backslash, and
# an unescaped one produces a line the host cannot parse — which it reports as a protocol breach
# (40) rather than as whatever the run actually found.
# ---------------------------------------------------------------------------
line="$(run_with_fd3 'emit_event case_replayed file "a\"b\\c"')"
assert_contains "$line" '"file":"a\"b\\c"' "quotes and backslashes are escaped, backslash first"
line="$(run_with_fd3 "emit_event error detail \"$(printf 'x\ty\nz')\"")"
assert_contains "$line" '\t' "a tab becomes \\t"
assert_contains "$line" '\n' "a newline becomes \\n, keeping the event on ONE line"
assert_eq "1" "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" "a value with a newline still produces exactly one line"
line="$(run_with_fd3 "emit_event error detail \"$(printf 'a\001b')\"")"
ctrl_escape="$(printf 'a\\u0001b')"
assert_contains "$line" "$ctrl_escape" "a control character below 0x20 becomes a unicode escape"

# A mis-paired field list must be visible, not silently dropped.
line="$(run_with_fd3 'emit_event odd k v trailing')"
assert_contains "$line" '_malformed_trailing_field' "an odd trailing argument is surfaced, not swallowed"

# ---------------------------------------------------------------------------
# Standalone bash: fd 3 closed. The engine has to keep working when nobody is listening (§4).
# ---------------------------------------------------------------------------
out="$(run_without_fd3 'emit_event x k v; echo ALIVE')"
assert_eq "ALIVE" "$out" "with fd 3 closed emit_event is a silent no-op and the script continues"
out="$(run_without_fd3 'event_begin_command standalone.sh; echo ALIVE')"
assert_eq "ALIVE" "$out" "event_begin_command is equally harmless with fd 3 closed"

# ---------------------------------------------------------------------------
# command_started / command_finished — exactly one terminator, whatever the exit path.
# ---------------------------------------------------------------------------
lines="$(run_with_fd3 'event_begin_command gate.sh; emit_event scenario_started name ut; exit 0')"
assert_eq "1" "$(grep -c '"ev":"command_started"' <<< "$lines")" "exactly one command_started"
assert_eq "1" "$(grep -c '"ev":"command_finished"' <<< "$lines")" "exactly one command_finished on a clean exit"
assert_contains "$lines" '"outcome":"pass","engine_exit":0' "a clean exit reports outcome=pass"
assert_eq "command_started" "$(head -1 <<< "$lines" | sed 's/.*"ev":"\([a-z_]*\)".*/\1/')" \
    "command_started comes first"
assert_eq "command_finished" "$(tail -1 <<< "$lines" | sed 's/.*"ev":"\([a-z_]*\)".*/\1/')" \
    "command_finished comes last"

# The trap is armed before parsing, so an early usage error still terminates properly. This is the
# case the host cannot recover from otherwise: a subprocess that dies with no command_finished is
# reported as fbt's own bug (40) when it is really the user's config error (20).
lines="$(run_with_fd3 'event_begin_command gate.sh; echo "ERROR: -p required" >&2; exit 2')"
assert_eq "1" "$(grep -c '"ev":"command_finished"' <<< "$lines")" "an early exit still emits command_finished"
assert_contains "$lines" '"outcome":"config_error","engine_exit":2' "exit 2 maps to config_error"

# A crash is engine_error, NOT gate_fail: calling every non-zero exit a gate failure would turn a
# broken engine into a clean "the chain has a bug" verdict.
lines="$(run_with_fd3 'event_begin_command gate.sh; exit 9')"
assert_contains "$lines" '"outcome":"engine_error","engine_exit":9' "an unexplained non-zero exit is engine_error"

# An explicit verdict wins over the exit-code fallback.
lines="$(run_with_fd3 'event_begin_command gate.sh; event_set_outcome gate_fail; exit 1')"
assert_contains "$lines" '"outcome":"gate_fail","engine_exit":1' "event_set_outcome overrides the fallback"

# set -e killing the script mid-way is still a termination the host must see.
lines="$(run_with_fd3 'event_begin_command gate.sh; false; echo unreachable')"
assert_eq "1" "$(grep -c '"ev":"command_finished"' <<< "$lines")" "a set -e abort still emits command_finished"

# A script that exits from inside a function must not emit two terminators.
lines="$(run_with_fd3 'event_begin_command gate.sh; f() { exit 3; }; f')"
assert_eq "1" "$(grep -c '"ev":"command_finished"' <<< "$lines")" "exiting from a function emits one terminator"

# A caught signal must NOT report a clean pass. Bash runs the EXIT trap when a script is TERMed,
# but $? inside it is the last command's status, not the signal — measured before the signal traps
# existed, `kill -TERM` produced {"outcome":"pass","engine_exit":0}. Since the host maps its exit
# code from `outcome` alone, a gate run the host TERMed on timeout would have come back a PASS.
lines="$(run_with_fd3 'event_begin_command gate.sh; kill -TERM $$; sleep 5')"
assert_eq "1" "$(grep -c '"ev":"command_finished"' <<< "$lines")" "a TERM emits exactly one terminator"
assert_not_contains "$lines" '"outcome":"pass"' "a killed engine must never report a pass"
assert_contains "$lines" '"outcome":"engine_error"' "a TERM reports engine_error"
assert_contains "$lines" '"engine_exit":143' "a TERM reports the conventional 128+15"
assert_contains "$lines" '"signal":"TERM"' "the terminator names the signal"

# SIGKILL cannot be caught, so nothing is emitted — which is precisely the "terminated with no
# command_finished" condition the host reads as an engine that died unexpectedly (40).
lines="$(run_with_fd3 'event_begin_command gate.sh; kill -KILL $$; sleep 5')"
assert_eq "0" "$(grep -c '"ev":"command_finished"' <<< "$lines")" \
    "a KILL emits no terminator, which is what tells the host the engine died"

assert_done
