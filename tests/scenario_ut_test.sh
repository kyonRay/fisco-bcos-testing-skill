#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/scenarios/scenario_ut.sh
assert_eq "0" "$(type -t scenario_ut_run > /dev/null && echo 0 || echo 1)" "function defined"

# Hermetic: point BUILD_DIR at a checked-in fixture (2 fake module UT binaries) instead of the
# ambient FISCO-BCOS build/ tree, so this test passes the same way on a fresh checkout with no
# cmake build yet as it does on a machine with a full build/ present.
FIXTURE_BUILD_DIR="$(pwd)/tests/fixtures/fake-build"

# dry 模式只列出将跑的模块,不真跑
out="$(BUILD_DIR="$FIXTURE_BUILD_DIR" SCENARIO_DRY=1 scenario_ut_run /tmp/x)"
assert_contains "$out" "run_ut.sh" "delegates to run_ut.sh"
assert_contains "$out" "txpool" "fixture module txpool discovered (shallow: test/test-bcos-*)"
# The fixture puts executor at test/unittest/test-bcos-executor, mirroring the real tree — the only
# module that nests one level deeper. The fixed-depth glob this enumeration used to rely on finds
# txpool and misses executor, so a gate round reported "ran every module" having skipped the
# executor entirely. Discovering BOTH is the regression this asserts.
assert_contains "$out" "executor" "fixture module executor discovered (deep: test/unittest/test-bcos-*)"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c 'run_ut.sh')" "both fixture modules enumerated, not just the shallow one"

# No built binaries at all (e.g. a fresh checkout before cmake finishes) -> deterministic
# no-modules path: dry mode still returns 0, and emits no "run_ut.sh" command (nothing to run).
EMPTY_BUILD_DIR="$(mktemp -d)"
out_empty="$(BUILD_DIR="$EMPTY_BUILD_DIR" SCENARIO_DRY=1 scenario_ut_run /tmp/x 2>/dev/null)"
rc_empty=$?
assert_eq "0" "$rc_empty" "empty BUILD_DIR still returns 0"
assert_not_contains "$out_empty" "run_ut.sh" "empty BUILD_DIR emits no run_ut.sh command"

# ...but a REAL run with zero UT binaries must FAIL, not pass. A live gate round on a -DTESTS=OFF
# build reported "scenario 'ut' PASSED" having executed nothing; zero evidence is not health.
rc_real=0
BUILD_DIR="$EMPTY_BUILD_DIR" scenario_ut_run /tmp/x >/dev/null 2>&1 || rc_real=$?
assert_eq "1" "$rc_real" "real run with zero UT binaries FAILS (no false green on absent evidence)"
rmdir "$EMPTY_BUILD_DIR"

assert_done
