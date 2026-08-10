#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"; source "$SD/../scripts/oracle_lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"/node{0,1,2}
printf '[web3_rpc]\n    enable=true\n    listen_ip=0.0.0.0\n    listen_port=8545\n' > "$tmp/node0/config.ini"
printf '[web3_rpc]\n    enable=true\n    listen_ip=::\n    listen_port=8546\n'      > "$tmp/node1/config.ini"
printf '[web3_rpc]\n    enable=false\n    listen_port=8547\n'                        > "$tmp/node2/config.ini"
out="$(_discover_stateroot_urls "$tmp")"
assert_contains "$out" "http://127.0.0.1:8545" "0.0.0.0 -> loopback"
assert_contains "$out" "http://[::1]:8546" "IPv6 :: -> [::1] bracketed"
assert_not_contains "$out" "8547" "web3-disabled node excluded"
out2="$(_discover_stateroot_urls "$tmp" "http://x:9,http://127.0.0.1:8545")"
assert_eq "1" "$(printf '%s\n' "$out2" | grep -c '127.0.0.1:8545')" "duplicate collapsed"
assert_contains "$out2" "http://x:9" "extra appended"
solo="$(mktemp -d)"; mkdir -p "$solo/node0"; printf '[web3_rpc]\n    enable=true\n    listen_port=8545\n' > "$solo/node0/config.ini"
rc=0; _discover_stateroot_urls "$solo" >/dev/null 2>&1 || rc=$?; assert_eq "3" "$rc" "<2 -> rc3"; rm -rf "$solo"
assert_done
