#!/usr/bin/env bash
# tests/engine_events_test.sh — every directly-launched engine command must emit exactly one
# command_started and exactly one command_finished on fd 3 (design doc §8), including on the early
# usage-error paths, and must accept the host's workspace instead of a fixed directory name.
#
# These run the real scripts as real subprocesses with fd 3 captured. --dry-run and deliberate
# usage errors keep every case off a live chain.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
PROFILE="$PWD/profiles/production-enterprise.profile"

# capture <script> <args...> — run it with fd 3 to a file; echo the events, remember the exit code.
# capture runs inside $(...), so a variable it assigns dies with the subshell. The exit status
# goes through a file, which the caller reads via last_rc.
capture() {
    local out="$tmp/ev.$RANDOM" rc=0
    "$@" 3> "$out" > "$tmp/out" 2> "$tmp/err" || rc=$?
    printf '%s' "$rc" > "$tmp/rc"
    cat "$out"
}
last_rc() { cat "$tmp/rc"; }

started() { grep -c '"ev":"command_started"' <<< "$1" || true; }
finished() { grep -c '"ev":"command_finished"' <<< "$1" || true; }

# ---------------------------------------------------------------------------
# Every entry point, on its --dry-run path: one started, one finished, outcome pass.
# ---------------------------------------------------------------------------
for spec in \
    "gate.sh|bash scripts/gate.sh -p $PROFILE --dry-run" \
    "apply_profile.sh|bash scripts/apply_profile.sh -p $PROFILE --dry-run" \
    "run_case.sh|bash scripts/run_case.sh scenarios/example.case --dry-run" \
    "gate_upgrade.sh|bash scripts/gate_upgrade.sh -p $PROFILE --old-bin $PROFILE --new-bin $PROFILE --target-ver 3.17.0 --dry-run"
do
    name="${spec%%|*}"; cmd="${spec#*|}"
    ev="$(capture $cmd)"
    assert_eq "0" "$(last_rc)" "$name --dry-run exits 0"
    assert_eq "1" "$(started "$ev")" "$name emits exactly one command_started"
    assert_eq "1" "$(finished "$ev")" "$name emits exactly one command_finished"
    assert_contains "$ev" "\"cmd\":\"$name\"" "$name names itself in its events"
    assert_contains "$ev" '"outcome":"pass"' "$name reports outcome=pass on a clean dry run"
done

# fuzz_bcos.sh's -h path is its cheapest real execution: it proves the guard-scoped
# event_begin_command fires when the file is EXECUTED.
ev="$(capture bash scripts/fuzz_bcos.sh -h)"
assert_eq "1" "$(started "$ev")" "fuzz_bcos.sh emits command_started when executed"
assert_eq "1" "$(finished "$ev")" "fuzz_bcos.sh emits command_finished when executed"

# ...and stays silent when merely SOURCED, which tests do for its functions. Arming the trap at
# file scope would install it on the sourcing shell and emit that shell's termination as if it
# were an engine command.
ev="$(capture bash -c 'source scripts/fuzz_bcos.sh; echo sourced >/dev/null')"
assert_eq "0" "$(started "$ev")" "sourcing fuzz_bcos.sh emits nothing"
assert_eq "0" "$(finished "$ev")" "sourcing fuzz_bcos.sh installs no EXIT trap"

# ---------------------------------------------------------------------------
# The early usage-error path. This is the case the whole "arm the trap first" rule exists for: a
# subprocess that dies with no command_finished is read by the host as fbt's own bug (40), when in
# truth the user forgot a flag (20).
# ---------------------------------------------------------------------------
for spec in \
    "gate.sh|bash scripts/gate.sh" \
    "apply_profile.sh|bash scripts/apply_profile.sh" \
    "run_case.sh|bash scripts/run_case.sh" \
    "gate_upgrade.sh|bash scripts/gate_upgrade.sh -p $PROFILE"
do
    name="${spec%%|*}"; cmd="${spec#*|}"
    ev="$(capture $cmd)"
    assert_eq "2" "$(last_rc)" "$name with no required flags exits 2"
    assert_eq "1" "$(finished "$ev")" "$name still emits command_finished on a usage error"
    assert_contains "$ev" '"outcome":"config_error","engine_exit":2' "$name maps exit 2 to config_error"
done

# A configured path that points nowhere is infrastructure, not usage -- the two get different exit
# codes from the host, so the engine must not report them the same way.
ev="$(capture bash scripts/gate_upgrade.sh -p "$PROFILE" --old-bin /no/such/bin \
        --new-bin "$PROFILE" --target-ver 3.17.0)"
assert_contains "$ev" '"outcome":"infra_error"' "a missing binary is infra_error, not config_error"

# A long flag with no value must be a clean usage error, not a `set -u` crash.
ev="$(capture bash scripts/gate_upgrade.sh -p "$PROFILE" --old-bin)"
assert_eq "2" "$(last_rc)" "a value-less long flag is a usage error"
assert_contains "$ev" '"outcome":"config_error"' "...and is reported as config_error"

# ---------------------------------------------------------------------------
# Workspace parameterisation. The engine's cwd stays the repo root (§7.3), so isolation can only
# come from being TOLD where to build -- a fixed ./nodes-release-gate would make two concurrent
# runs share one cluster directory.
# ---------------------------------------------------------------------------
assert_contains "$(bash scripts/gate.sh -p "$PROFILE" -o /tmp/fbt-ws-gate --dry-run 2>&1)" \
    "/tmp/fbt-ws-gate" "gate.sh -o reaches the resolved plan"
assert_contains "$(bash scripts/run_case.sh scenarios/example.case -o /tmp/fbt-ws-case --dry-run 2>&1)" \
    "/tmp/fbt-ws-case" "run_case.sh -o reaches the resolved plan"
assert_contains "$(bash scripts/gate_upgrade.sh -p "$PROFILE" --old-bin "$PROFILE" \
    --new-bin "$PROFILE" --target-ver 3.17.0 -o /tmp/fbt-ws-upg --dry-run 2>&1)" \
    "/tmp/fbt-ws-upg" "gate_upgrade.sh -o reaches the resolved plan"

# Without -o the old fixed names remain, so a standalone run behaves exactly as before.
assert_contains "$(bash scripts/gate.sh -p "$PROFILE" --dry-run 2>&1)" \
    "nodes-release-gate" "gate.sh keeps its standalone default"

# ---------------------------------------------------------------------------
# Standalone: fd 3 closed. Nothing may change, and no event text may leak into stdout.
# ---------------------------------------------------------------------------
out="$(bash scripts/gate.sh -p "$PROFILE" --dry-run 2>&1)"
assert_not_contains "$out" '"schema_version"' "with fd 3 closed no event text leaks into stdout"
assert_not_contains "$out" 'command_started' "...not even the event names"

# ---------------------------------------------------------------------------
# A profile that is not there is a CONFIGURATION error, not an engine fault. The event protocol
# maps exit 2 to config_error (20) and every other non-zero to engine_error (40), so exit 1 here
# reported a mistyped -p as an fbt bug -- observed end to end before this was fixed:
# `fbt gate run -p production-enterprise` came back exit 40, "gate.sh failed with an engine fault".
# ---------------------------------------------------------------------------
for spec in \
    "gate.sh|bash scripts/gate.sh -p /no/such.profile" \
    "apply_profile.sh|bash scripts/apply_profile.sh -p /no/such.profile"
do
    name="${spec%%|*}"; cmd="${spec#*|}"
    ev="$(capture $cmd)"
    assert_eq "2" "$(last_rc)" "$name: a missing profile exits 2"
    assert_contains "$ev" '"outcome":"config_error"' "$name: a missing profile is config_error, not engine_error"
done

# The same for a .case whose profile does not resolve.
bad_case="$tmp/badprofile.case"
printf '[case]\nstatus = active\nprofile = /no/such.profile\ninput = true\nexpect_oracle = pass\n' > "$bad_case"
ev="$(capture bash scripts/run_case.sh "$bad_case")"
assert_eq "2" "$(last_rc)" "run_case.sh: a case naming a missing profile exits 2"
assert_contains "$ev" '"outcome":"config_error"' "run_case.sh: ...and is config_error"

# ---------------------------------------------------------------------------
# A broken INSTALLATION is infra_error (30, "fix the test machine"), not engine_error (40, "file a
# bug against fbt"). Before gate.sh named its own outcomes, the protocol's rc fallback called every
# non-zero exit an engine fault, and a machine missing the sibling skill really did report 40.
#
# Hermetic: a scripts dir holding gate.sh and the libraries it sources, but no apply_profile.sh.
# ---------------------------------------------------------------------------
broken="$tmp/broken-install"
mkdir -p "$broken"
cp scripts/gate.sh scripts/event_lib.sh scripts/profile_lib.sh scripts/oracle_lib.sh \
   scripts/failures_lib.sh "$broken/"
cp -r scripts/scenarios "$broken/scenarios"
ev="$(capture bash "$broken/gate.sh" -p "$PROFILE" -o "$tmp/ws")"
assert_contains "$ev" '"outcome":"infra_error"' \
    "a missing apply_profile.sh is infra_error, not engine_error"
assert_not_contains "$ev" '"outcome":"engine_error"' \
    "...and is never reported as an fbt bug"

assert_done
