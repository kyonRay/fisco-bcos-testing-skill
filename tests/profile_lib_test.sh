#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/profile_lib.sh
profile_load tests/fixtures/sample.profile
assert_eq "3.16.4" "${PROFILE_GENESIS[compatibility_version]}" "genesis parsed"
assert_eq "1" "${PROFILE_REPLAY[feature_balance]}" "replay flag parsed"
assert_eq "500" "${PROFILE_REPLAY[tx_count_limit]}" "replay int parsed"
assert_eq "true" "${PROFILE_CONFIG[executor.enable_dag]}" "config override parsed"
assert_contains "$(profile_replay_pairs)" "feature_balance 1" "replay pairs emitted"
assert_contains "$(profile_config_pairs)" "executor.enable_dag true" "config pairs emitted"
assert_done
