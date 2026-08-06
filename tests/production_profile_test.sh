#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh; source scripts/profile_lib.sh
profile_load profiles/production-enterprise.profile
assert_eq "3.16.4" "${PROFILE_GENESIS[compatibility_version]}" "prod compat ver"
assert_eq "1" "${PROFILE_REPLAY[feature_evm_cancun]}" "cancun on"
assert_eq "500" "${PROFILE_REPLAY[tx_count_limit]}" "tx_count_limit"
assert_eq "true" "${PROFILE_CONFIG[executor.enable_dag]}" "dag on (faithful)"
assert_eq "" "${PROFILE_REPLAY[bugfix_auth_check]:-}" "new bugfix flag stays null"
assert_done
