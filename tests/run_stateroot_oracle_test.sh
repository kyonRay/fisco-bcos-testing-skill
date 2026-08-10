#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"; source "$SD/../scripts/oracle_lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/two"/node{0,1}
printf '[web3_rpc]\n enable=true\n listen_port=8545\n' > "$tmp/two/node0/config.ini"
printf '[web3_rpc]\n enable=true\n listen_port=8546\n' > "$tmp/two/node1/config.ini"
mkdir -p "$tmp/one/node0"; printf '[web3_rpc]\n enable=true\n listen_port=8545\n' > "$tmp/one/node0/config.ini"
export STATEROOT_ORACLE="$tmp/fake.sh" RFLAGS="$tmp/rflags"
printf '#!/usr/bin/env bash\necho "$@" >> "$RFLAGS"\nexit "${FAKE_RC:-0}"\n' > "$STATEROOT_ORACLE"; chmod +x "$STATEROOT_ORACLE"
rc=0; FAKE_RC=0 _run_stateroot_oracle 5 "$tmp/two" "" || rc=$?; assert_eq "0" "$rc" "clean -> 0"
assert_contains "$(cat "$RFLAGS")" "-r http://127.0.0.1:8545" "both urls passed as -r"
assert_contains "$(cat "$RFLAGS")" "-r http://127.0.0.1:8546" "second url passed"
rc=0; FAKE_RC=1 _run_stateroot_oracle 5 "$tmp/two" "" || rc=$?; assert_eq "1" "$rc" "divergence -> 1"
rc=0; _run_stateroot_oracle 5 "$tmp/one" "" || rc=$?; assert_eq "3" "$rc" "single node -> infra 3 (oracle not consulted)"
assert_done
