#!/usr/bin/env bash
# scenario_ut.sh — "ut" gate scenario family: run every built module's unit-test binary via the
# sibling fisco-bcos-testing skill's run_ut.sh, one module at a time.
#
# This file is SOURCED (by gate.sh's `for f in "$SCRIPT_DIR"/scenarios/*.sh; do source "$f";
# done` loop — see scripts/gate.sh — or standalone by tests/scenario_ut_test.sh), so it must not
# `set -e`/`set -u` at file scope: that would change the sourcing script's own shell options.
# Registration at the bottom is guarded for the same reason (see there).
#
# Env:
#   SCENARIO_DRY=1   print the run_ut.sh commands that would run, one per built module, and
#                    return 0 without executing anything. This is the only path exercised by
#                    this repo's own tests — there are no built UT binaries in this environment,
#                    only in a live FISCO-BCOS checkout with a completed cmake build.
#   BUILD_DIR        override the FISCO-BCOS build tree to search (default: <repo root>/build,
#                    matching run_ut.sh's own default).
#   FBT_REPO_ROOT    override repo-root discovery outright (no upward walk) — needed in an
#                    installed libexec layout, where this script no longer lives inside a
#                    FISCO-BCOS checkout for tools/BcosAirBuilder/build_chain.sh to walk up to.
#   FBT_ENGINE_SCRIPTS  directory to look for run_ut.sh in first (ahead of the dev-checkout
#                    sibling fisco-bcos-testing/scripts) — the other half of the libexec case.

SCENARIO_UT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCENARIO_UT_SELF_DIR is the resolver's "own dir" candidate — overridable so tests can eval just
# the resolver function against a fixture dir without sourcing this whole file.
SCENARIO_UT_SELF_DIR="${SCENARIO_UT_SELF_DIR:-$SCENARIO_UT_DIR}"

# _scenario_ut_resolve_run_ut — abs path to the sibling fisco-bcos-testing run_ut.sh, tried in
# the SAME order apply_profile.sh's _resolve_engine_script uses: $FBT_ENGINE_SCRIPTS (installed
# libexec layout with no sibling checkout) -> this script's own dir -> the dev-checkout sibling.
# This script lives one directory deeper than apply_profile.sh (under scripts/scenarios/, not
# scripts/), hence the extra ".." on the sibling candidate. Returns 1 if none of the three has it.
_scenario_ut_resolve_run_ut() {
    local c
    for c in "${FBT_ENGINE_SCRIPTS:-}" "$SCENARIO_UT_SELF_DIR" "$SCENARIO_UT_SELF_DIR/../../../fisco-bcos-testing/scripts"; do
        [[ -n "$c" && -f "$c/run_ut.sh" ]] && { echo "$c/run_ut.sh"; return 0; }
    done
    return 1
}

# scenario_ut_find_repo_root — honors $FBT_REPO_ROOT first (an installed libexec layout has no
# tools/BcosAirBuilder/build_chain.sh marker to walk up to, so the caller must say where the repo
# is). Otherwise walk up from this script's own dir (not $PWD) looking for the same repo marker
# run_ut.sh's own find_repo_root uses, so BUILD_DIR discovery is cwd-independent too. Not a
# reimplementation of run_ut.sh's per-module binary lookup/fallback — only enough to locate the
# build tree once so we can enumerate which modules were actually built.
scenario_ut_find_repo_root() {
    [[ -n "${FBT_REPO_ROOT:-}" ]] && { echo "$FBT_REPO_ROOT"; return 0; }
    local d="$SCENARIO_UT_DIR"
    while [[ "$d" != "/" ]]; do
        [[ -f "$d/tools/BcosAirBuilder/build_chain.sh" ]] && { echo "$d"; return 0; }
        d="$(dirname "$d")"
    done
    return 1
}

# scenario_ut_run [outdir] — run every built module's UT binary; return 1 if any fails.
# [outdir] is accepted for interface symmetry with the other gate scenarios (gate.sh's
# GATE_SCENARIOS dispatch currently calls scenario functions with no arguments) but unused here:
# UT has no cluster to write logs under, and run_ut.sh already prints PASS/FAIL to stdout/stderr.
scenario_ut_run() {
    local repo_root build_dir run_ut
    repo_root="$(scenario_ut_find_repo_root)" || {
        echo "ERROR: scenario_ut: not inside a FISCO-BCOS checkout (no tools/BcosAirBuilder/build_chain.sh found above $SCENARIO_UT_DIR, and \$FBT_REPO_ROOT not set)" >&2
        return 1
    }
    build_dir="${BUILD_DIR:-$repo_root/build}"

    run_ut="$(_scenario_ut_resolve_run_ut)" || {
        echo "ERROR: scenario_ut: run_ut.sh not found (tried \$FBT_ENGINE_SCRIPTS, $SCENARIO_UT_SELF_DIR, sibling fisco-bcos-testing/scripts — expected the fisco-bcos-testing skill checked out alongside this one, or FBT_ENGINE_SCRIPTS set)" >&2
        return 1
    }

    # Enumerate built module UT binaries by the same conventional path run_ut.sh itself prefers
    # (build/bcos-<module>/test/test-bcos-<module>) — run_ut.sh has no "list all modules" mode of
    # its own, so this enumeration is ours to do; the actual run/pass-fail decision is still
    # entirely delegated to run_ut.sh below.
    # Search by name at any depth, NOT with a fixed-depth glob: bcos-executor's binary sits one
    # level deeper (test/unittest/test-bcos-executor) than everyone else's (test/test-bcos-*), so
    # the fixed glob silently dropped the executor — the single most important module here — while
    # the scenario still reported "ran every built module's UT binary" and PASSED. Enumerating 16
    # of 17 modules and calling it complete is the same false green as running none.
    local modules=() bin module
    while IFS= read -r bin; do
        [[ -x "$bin" ]] || continue
        module="$(basename "$bin")"
        module="${module#test-bcos-}"
        modules+=("$module")
    done < <(find "$build_dir" -type f -name 'test-bcos-*' 2>/dev/null | sort)

    if [[ ${#modules[@]} -eq 0 ]]; then
        # A release gate that reports PASS after running ZERO tests is the exact false green this
        # harness exists to catch. "No UT binaries" is not evidence of health — it is absence of
        # evidence, and on a real run that must fail the gate. (A build configured -DTESTS=OFF is
        # the usual cause; a live run against one silently "passed" this scenario before the fix.)
        # Dry mode still returns 0: it only prints a plan and never claims evidence either way.
        if [[ "${SCENARIO_DRY:-0}" == 1 ]]; then
            echo "DRY: scenario_ut: no built module UT binaries under $build_dir/bcos-*/test/test-bcos-* — a real run would FAIL here"
            return 0
        fi
        echo "ERROR: scenario_ut: no built module UT binaries found under $build_dir/bcos-*/test/test-bcos-*" >&2
        echo "       Zero UT evidence cannot pass a release gate — reporting FAIL, not a skip." >&2
        echo "       Build them first: configure with -DTESTS=ON, then e.g." >&2
        echo "         cmake --build $build_dir --target test-bcos-txpool -j" >&2
        return 1
    fi

    if [[ "${SCENARIO_DRY:-0}" == 1 ]]; then
        for module in "${modules[@]}"; do
            echo "DRY: BUILD_DIR=$build_dir bash $run_ut $module"
        done
        return 0
    fi

    local rc=0
    for module in "${modules[@]}"; do
        echo ">> scenario_ut: running module UT: $module"
        BUILD_DIR="$build_dir" bash "$run_ut" "$module" || rc=1
    done
    return $rc
}

# Register into gate.sh's GATE_SCENARIOS map. Guarded: when this file is sourced standalone
# (e.g. by tests/scenario_ut_test.sh) rather than via gate.sh, gate.sh's own
# `declare -A GATE_SCENARIOS=()` has not run yet, so under `set -u` a bare assignment into
# GATE_SCENARIOS[ut]=... would abort the sourcing script with "unbound variable". Declare it
# (idempotently — declare -A on an already-declared array is a harmless no-op, never resets an
# existing map) before the assignment so standalone sourcing never crashes.
declare -gA GATE_SCENARIOS 2>/dev/null || true
GATE_SCENARIOS[ut]=scenario_ut_run
