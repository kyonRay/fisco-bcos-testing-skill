#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
out="$(bash scripts/gate.sh -p profiles/production-enterprise.profile --scenarios ut --dry-run)"
assert_contains "$out" "profile: production-enterprise" "dry-run names profile"
assert_contains "$out" "scenario: ut" "dry-run lists scenario"
# 未知场景名应报错非0
bash scripts/gate.sh -p profiles/production-enterprise.profile --scenarios nope --dry-run && r=0 || r=1
assert_eq "1" "$r" "unknown scenario rejected"
assert_done
