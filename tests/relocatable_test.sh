#!/usr/bin/env bash
# relocatable_test.sh — proves the engine can run from a location with NO sibling
# fisco-bcos-testing checkout (an installed libexec layout), by simulating that layout: a
# stub-only FBT_ENGINE_SCRIPTS dir that must win over the real dev-checkout sibling, then the
# reverse (unset it) to prove the sibling fallback still resolves in this dev checkout.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"

# ---------------------------------------------------------------------------
# engine.json — present, three distinct version keys.
# ---------------------------------------------------------------------------
ej="$SD/../engine.json"
assert_eq "0" "$([[ -f "$ej" ]] && echo 0 || echo 1)" "engine.json present"
for k in engine_protocol_version event_schema_version output_schema_version; do
    assert_contains "$(cat "$ej")" "$k" "engine.json has $k"
done

# ---------------------------------------------------------------------------
# apply_profile.sh's _resolve_engine_script: FBT_ENGINE_SCRIPTS wins, sibling is the fallback.
# ---------------------------------------------------------------------------
eval "$(sed -n '/^_resolve_engine_script()/,/^}/p' "$SD/../scripts/apply_profile.sh")"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp" "${tmp2:-}"' EXIT
: > "$tmp/cluster_up.sh"

# Simulate the no-sibling installed layout: FBT_ENGINE_SCRIPTS is the ONLY place the script
# exists (a nonexistent _SELF_DIR proves the self-dir candidate is not what resolved it).
got="$(FBT_ENGINE_SCRIPTS="$tmp" _SELF_DIR="$tmp/not-here" _resolve_engine_script cluster_up.sh)"
assert_eq "$tmp/cluster_up.sh" "$got" "FBT_ENGINE_SCRIPTS wins over sibling/self-dir"

# Unset FBT_ENGINE_SCRIPTS and point _SELF_DIR at the real scripts/ dir (no cluster_up.sh there
# either) — resolution must fall through to the dev-checkout sibling, still present here.
self_dir_ap="$(cd "$SD/../scripts" && pwd)"
got_sibling="$(unset FBT_ENGINE_SCRIPTS; _SELF_DIR="$self_dir_ap" _resolve_engine_script cluster_up.sh)"
assert_eq "$self_dir_ap/../../fisco-bcos-testing/scripts/cluster_up.sh" "$got_sibling" \
    "falls back to sibling fisco-bcos-testing/scripts (still resolvable in this dev checkout)"

# ---------------------------------------------------------------------------
# scenario_ut.sh's run_ut resolver: same FBT_ENGINE_SCRIPTS -> self -> sibling order.
# ---------------------------------------------------------------------------
eval "$(sed -n '/^_scenario_ut_resolve_run_ut()/,/^}/p' "$SD/../scripts/scenarios/scenario_ut.sh")"

tmp2="$(mktemp -d)"
: > "$tmp2/run_ut.sh"

got_ut="$(FBT_ENGINE_SCRIPTS="$tmp2" SCENARIO_UT_SELF_DIR="$tmp2/not-here" _scenario_ut_resolve_run_ut)"
assert_eq "$tmp2/run_ut.sh" "$got_ut" "scenario_ut run_ut resolver: FBT_ENGINE_SCRIPTS wins"

self_dir_ut="$(cd "$SD/../scripts/scenarios" && pwd)"
got_ut_sibling="$(unset FBT_ENGINE_SCRIPTS; SCENARIO_UT_SELF_DIR="$self_dir_ut" _scenario_ut_resolve_run_ut)"
assert_eq "$self_dir_ut/../../../fisco-bcos-testing/scripts/run_ut.sh" "$got_ut_sibling" \
    "scenario_ut run_ut resolver: falls back to sibling"

# ---------------------------------------------------------------------------
# scenario_ut_find_repo_root: FBT_REPO_ROOT wins, no upward walk performed.
# ---------------------------------------------------------------------------
eval "$(sed -n '/^scenario_ut_find_repo_root()/,/^}/p' "$SD/../scripts/scenarios/scenario_ut.sh")"
assert_eq "/my/repo" "$(FBT_REPO_ROOT=/my/repo scenario_ut_find_repo_root)" "repo root honors FBT_REPO_ROOT"

# ---------------------------------------------------------------------------
# scenario_jsd.sh honors JAVA_BIN.
# ---------------------------------------------------------------------------
assert_contains "$(grep -n 'JAVA_BIN' "$SD/../scripts/scenarios/scenario_jsd.sh")" "JAVA_BIN" "jsd honors JAVA_BIN"

assert_done
