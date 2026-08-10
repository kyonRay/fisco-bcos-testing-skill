#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
out="$(bash scripts/gate.sh -p profiles/production-enterprise.profile --scenarios ut --dry-run)"
assert_contains "$out" "profile: production-enterprise" "dry-run names profile"
assert_contains "$out" "scenario: ut" "dry-run lists scenario"
assert_contains "$out" "discover" "dry-run announces runtime multi-node stateRoot discovery"
# 未知场景名应报错非0 (config error, see _gate_validate_scenarios classification below)
bash scripts/gate.sh -p profiles/production-enterprise.profile --scenarios nope --dry-run && r=0 || r=1
assert_eq "1" "$r" "unknown scenario rejected"

# The default (--scenarios omitted) set is now exactly the four runnable families. 'upgrade' is
# no longer a GATE_KNOWN_SCENARIOS member (Design Decision rev3 #5) — selecting it is a config
# error (_gate_validate_scenarios rc 2), not something the default sweep silently skips.
default_out="$(bash scripts/gate.sh -p profiles/production-enterprise.profile --dry-run)"
assert_contains "$default_out" "scenario: ut" "default sweep includes ut"
assert_contains "$default_out" "scenario: dual_rpc" "default sweep includes dual_rpc"
assert_contains "$default_out" "scenario: malformed" "default sweep includes malformed"
assert_contains "$default_out" "scenario: jsd" "default sweep includes jsd"
case "$default_out" in
    *"scenario: upgrade"*) echo "FAIL: default sweep must not include upgrade" >&2; exit 1 ;;
esac

# _gate_validate_scenarios: DISTINCT exit codes per class (Design Decision rev3 #5) — 2 = config
# error (upgrade selected, or an unknown name), 3 = engine/setup fault (a known name with no
# registered function — its scenario file didn't source).
eval "$(sed -n '/^_gate_validate_scenarios()/,/^}/p' scripts/gate.sh)"
rc=0; _gate_validate_scenarios "ut dual_rpc malformed jsd" "ut malformed" upgrade 2>/dev/null || rc=$?; assert_eq "2" "$rc" "upgrade selected -> 2"
msg="$(_gate_validate_scenarios "ut" "ut" upgrade 2>&1 || true)"; assert_contains "$msg" "gate upgrade" "points to gate upgrade"
rc=0; _gate_validate_scenarios "ut malformed" "ut malformed" nonesuch 2>/dev/null || rc=$?; assert_eq "2" "$rc" "unknown -> 2"
rc=0; _gate_validate_scenarios "ut malformed" "ut" malformed 2>/dev/null || rc=$?; assert_eq "3" "$rc" "known-but-unregistered -> 3"
rc=0; _gate_validate_scenarios "ut malformed" "ut malformed" ut malformed 2>/dev/null || rc=$?; assert_eq "0" "$rc" "all good -> 0"
assert_done
