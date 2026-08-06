#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
out="$(bash scripts/apply_profile.sh -p profiles/production-enterprise.profile --dry-run)"
assert_contains "$out" "build_chain" "dry-run emits build_chain step"
assert_contains "$out" "compatibility_version 3.16.4" "dry-run genesis compat"
assert_contains "$out" "setSystemConfigByKey feature_evm_cancun 1" "dry-run replay cmd"
assert_contains "$out" "setSystemConfigByKey tx_count_limit 500" "dry-run replay int"
assert_contains "$out" "enable_dag = true" "dry-run config patch"
assert_not_contains "$out" "setSystemConfigByKey bugfix_auth_check" "null flags not replayed"
assert_done
