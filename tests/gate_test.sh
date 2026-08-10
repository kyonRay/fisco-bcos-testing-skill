#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
out="$(bash scripts/gate.sh -p profiles/production-enterprise.profile --scenarios ut --dry-run)"
assert_contains "$out" "profile: production-enterprise" "dry-run names profile"
assert_contains "$out" "scenario: ut" "dry-run lists scenario"
assert_contains "$out" "discover" "dry-run announces runtime multi-node stateRoot discovery"
# 未知场景名应报错非0
bash scripts/gate.sh -p profiles/production-enterprise.profile --scenarios nope --dry-run && r=0 || r=1
assert_eq "1" "$r" "unknown scenario rejected"

# FINAL REVIEW fix: the default (--scenarios omitted) sweep must not treat 'upgrade' as an
# automatic failure — scenario_upgrade_run needs <outdir> <old_bin> <new_bin> <target_ver>, which
# gate.sh's real-run bare-dispatch loop cannot supply. --dry-run flags 'upgrade' as needs-args (it
# is still a valid GATE_KNOWN_SCENARIOS entry — the name itself is not rejected), so the runnable
# default set can be told apart from a genuine unknown-scenario rejection above.
default_out="$(bash scripts/gate.sh -p profiles/production-enterprise.profile --dry-run)"
assert_contains "$default_out" "scenario: upgrade" "default sweep still includes upgrade as a known scenario"
assert_contains "$default_out" "needs-args: upgrade is SKIPped by the default bare-dispatch loop" \
    "default sweep flags upgrade as needs-args/SKIP, not a silent scenario_failed"
assert_done
