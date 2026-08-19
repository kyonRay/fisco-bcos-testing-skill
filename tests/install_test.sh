#!/usr/bin/env bash
# tests/install_test.sh — the packaging step produces a tree the host can actually drive.
#
# Every assertion here corresponds to a way an install has really been wrong:
#
#   - the whole repository once shipped at 0644, and nothing noticed, because every bash test
#     invokes scripts as `bash x.sh` while the host EXECS them;
#   - scripts/scenarios/ got flattened into scripts/, and gate.sh then reported "scenario 'ut'
#     selected but not registered" for an install containing every file;
#   - the sibling fisco-bcos-testing scripts were left behind, which only surfaces when a run
#     tries to build a chain.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh

command -v go >/dev/null || { echo "SKIP: no go toolchain"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
PREFIX="$tmp/dist"

# --no-sibling: this test is about THIS repository's packaging, and requiring the sibling checkout
# would make it fail on a machine where that skill is simply not present.
bash install.sh --prefix "$PREFIX" --no-sibling > "$tmp/install.log" 2>&1 || {
    echo "install.sh failed:"; cat "$tmp/install.log"; exit 1
}

assert_eq "1" "$([[ -x "$PREFIX/bin/fbt" ]] && echo 1 || echo 0)" "fbt is installed and executable"

# ---- exec bits ----
for n in gate.sh run_case.sh apply_profile.sh fuzz_bcos.sh gate_upgrade.sh cluster_down.sh \
         oracle_crash.sh oracle_liveness.sh oracle_stateroot.sh; do
    assert_eq "1" "$([[ -x "$PREFIX/libexec/fbt/scripts/$n" ]] && echo 1 || echo 0)" \
        "$n is executable (the host execs it; 0644 gives a bare permission denied)"
done
for lib in event_lib.sh profile_lib.sh oracle_lib.sh failures_lib.sh; do
    assert_eq "0" "$([[ -x "$PREFIX/libexec/fbt/scripts/$lib" ]] && echo 1 || echo 0)" \
        "$lib stays non-executable: an executable library invites someone to run it"
done

# ---- the scenarios subdirectory ----
assert_eq "1" "$([[ -d "$PREFIX/libexec/fbt/scripts/scenarios" ]] && echo 1 || echo 0)" \
    "scripts/scenarios/ survives as a subdirectory"
count=$(find "$PREFIX/libexec/fbt/scripts/scenarios" -name 'scenario_*.sh' | wc -l | tr -d ' ')
assert_eq "5" "$count" "all five scenario families are installed"
assert_eq "0" "$(find "$PREFIX/libexec/fbt/scripts" -maxdepth 1 -name 'scenario_*.sh' | wc -l | tr -d ' ')" \
    "no scenario file was flattened into scripts/"

# ---- data ----
assert_eq "1" "$([[ -f "$PREFIX/libexec/fbt/engine.json" ]] && echo 1 || echo 0)" "engine.json is installed"
assert_eq "1" "$([[ -f "$PREFIX/libexec/fbt/tools/tamper-helper.sh" ]] && echo 1 || echo 0)" \
    "the tamper helper is installed"
assert_eq "6" "$(find "$PREFIX/share/fbt/profiles" -name '*.profile' | wc -l | tr -d ' ')" \
    "all six profiles are installed"
# Only .case files: the source directory also holds README.md and .gitkeep, and a registry
# enumeration that tripped over those would refuse to run at all.
assert_eq "0" "$(find "$PREFIX/share/fbt/cases" -type f -not -name '*.case' | wc -l | tr -d ' ')" \
    "no non-case file leaked into share/fbt/cases"

# ---- the installed binary can drive the installed engine ----
FBT="$PREFIX/bin/fbt"
out="$("$FBT" --state-dir "$tmp/state" --output json case list)"
assert_contains "$out" '"swept"' "the installed fbt reads the installed cases"
out="$("$FBT" --state-dir "$tmp/state" --output json profile list)"
assert_contains "$out" "production-enterprise" "the installed fbt reads the installed profiles"

# The engine entry points really run under the installed layout. gate.sh's dry run resolves the
# profile, sources every scenario family and prints its plan -- which is the whole layout at once.
out="$("$FBT" --state-dir "$tmp/state" gate plan -p production-enterprise 2>&1)"
assert_contains "$out" "ut, dual_rpc, malformed, jsd" "gate plan resolves against the installed tree"

# ---- relocatable ----
# paths.Resolve derives the install root from the binary's own location, so a finished tree must
# work after being moved. A hardcoded path would only show up here.
mv "$PREFIX" "$tmp/moved"
out="$("$tmp/moved/bin/fbt" --state-dir "$tmp/state2" --output json config path)"
assert_contains "$out" "$tmp/moved/libexec/fbt/scripts" "the moved tree resolves its own new location"
assert_not_contains "$out" "$PREFIX/libexec" "no path from the original location survived the move"

assert_done
