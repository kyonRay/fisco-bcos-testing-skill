#!/usr/bin/env bash
# primary_web3_url_test.sh — _primary_web3_url (oracle_lib.sh) reads node0's Web3 RPC URL from
# its FINAL config.ini (base port and a WEB3_BASE-style override both land there the same way —
# apply_profile.sh's config.ini patch loop already resolved the precedence before this function
# ever runs), and cross-checks a host-injected WEB3_RPC_URL against it (Design Decision rev3 #2).
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"; source "$SD/../scripts/oracle_lib.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Base port: node0's config.ini reflects the profile's own captured web3_rpc.listen_port (no
# WEB3_BASE was set when apply_profile.sh patched it).
mkdir -p "$tmp/base/node0"
printf '[web3_rpc]\n    enable=true\n    listen_ip=0.0.0.0\n    listen_port=8545\n' > "$tmp/base/node0/config.ini"
assert_eq "http://127.0.0.1:8545" "$(_primary_web3_url "$tmp/base")" "base port (no override applied)"

# Override port: node0's config.ini reflects a WEB3_BASE=18545 override that apply_profile.sh's
# config.ini patch loop already wrote (via _apply_profile_web3_port) BEFORE this function runs —
# _primary_web3_url just reads whatever is actually there, so it picks up 18545 with no code of
# its own knowing an override happened.
mkdir -p "$tmp/override/node0"
printf '[web3_rpc]\n    enable=true\n    listen_ip=0.0.0.0\n    listen_port=18545\n' > "$tmp/override/node0/config.ini"
assert_eq "http://127.0.0.1:18545" "$(_primary_web3_url "$tmp/override")" "override port (WEB3_BASE-derived, already patched into config.ini)"

# WEB3_RPC_URL host-injection, consistent with node0's config.ini: returned as-is.
out="$(WEB3_RPC_URL="http://127.0.0.1:18545" _primary_web3_url "$tmp/override")"
assert_eq "http://127.0.0.1:18545" "$out" "WEB3_RPC_URL consistent with config.ini -> accepted"

# WEB3_RPC_URL host-injection, INCONSISTENT with node0's config.ini: refused (rc=1), not silently
# trusted — a stale WEB3_RPC_URL from an outer orchestrator must not make every oracle probe the
# wrong port while the cluster is actually healthy on the port config.ini names.
rc=0
WEB3_RPC_URL="http://127.0.0.1:9999" _primary_web3_url "$tmp/override" >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "WEB3_RPC_URL inconsistent with config.ini -> rc=1"

# Missing node0/config.ini -> rc=3 (infrastructure, same family as _discover_stateroot_urls's <2 rc=3).
rc=0
_primary_web3_url "$tmp/nope" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "no node0/config.ini -> rc=3"

# node0 web3_rpc not enabled -> rc=3.
mkdir -p "$tmp/disabled/node0"
printf '[web3_rpc]\n    enable=false\n    listen_port=8545\n' > "$tmp/disabled/node0/config.ini"
rc=0
_primary_web3_url "$tmp/disabled" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "node0 web3_rpc disabled -> rc=3"

assert_done
