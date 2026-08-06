#!/usr/bin/env bash
# archetype_profiles_test.sh — each of the 5 archetype profiles parses and carries its
# distinguishing "divergence axis" value (spec section 6's archetype table).
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh; source scripts/profile_lib.sh

# sm-gov: national-crypto (SM) deployment — divergence axis is p2p SM SSL.
profile_load profiles/sm-gov.profile
assert_eq "true" "${PROFILE_CONFIG[p2p.sm_ssl]:-}" "sm-gov: p2p.sm_ssl on"

# rpbft-scale: large-scale rPBFT — divergence axis is feature_rpbft + tree-mode tx broadcast,
# plus a larger node count than the default 4-node profile.
profile_load profiles/rpbft-scale.profile
assert_eq "1" "${PROFILE_REPLAY[feature_rpbft]:-}" "rpbft-scale: feature_rpbft on"
assert_eq "true" "${PROFILE_CONFIG[sync.send_txs_by_tree]:-}" "rpbft-scale: send_txs_by_tree on"
assert_eq "7" "${PROFILE_META[node_count]:-}" "rpbft-scale: node_count=7"

# default-latest: fresh open-source default chain — divergence axis is an EMPTY replay (no
# production-drift feature flags) plus the latest compatible genesis version. The "latest"
# version is derived elsewhere (grep DEFAULT_VERSION bcos-framework/.../Protocol.h); this test
# only asserts non-empty, never a hardcoded literal, so it doesn't rot when the default bumps.
profile_load profiles/default-latest.profile
assert_eq "" "$(profile_replay_pairs)" "default-latest: system_config_replay is empty"
if [[ -n "${PROFILE_GENESIS[compatibility_version]:-}" ]]; then
    echo "ok: default-latest: genesis compat non-empty"
else
    echo "FAIL: default-latest: genesis compat is empty" >&2
    _ASSERT_FAILS=1
fi

# evm-full: all EVM features on — divergence axis is every real feature_evm_* flag from
# Features.h (cancun, timestamp, address — there are no others; do not invent more).
profile_load profiles/evm-full.profile
assert_eq "1" "${PROFILE_REPLAY[feature_evm_cancun]:-}" "evm-full: feature_evm_cancun on"
assert_eq "1" "${PROFILE_REPLAY[feature_evm_timestamp]:-}" "evm-full: feature_evm_timestamp on"
assert_eq "1" "${PROFILE_REPLAY[feature_evm_address]:-}" "evm-full: feature_evm_address on"

# upgrade-legacy: old chain for long-distance upgrade testing — divergence axis is an old
# genesis compatibility_version so a gate scenario can replay a long jump to 3.17.
profile_load profiles/upgrade-legacy.profile
assert_eq "3.0.0" "${PROFILE_GENESIS[compatibility_version]:-}" "upgrade-legacy: old genesis compat"

assert_done
