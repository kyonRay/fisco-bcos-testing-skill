#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh; source scripts/oracle_lib.sh
# 停摆:有pending、35s、高度没涨 → 判失败
oracle_liveness_decide 100 100 35 1 && r=pass || r=halt
assert_eq "halt" "$r" "stall detected"
# 正常:高度涨了 → 判通过
oracle_liveness_decide 100 101 35 1 && r=pass || r=halt
assert_eq "pass" "$r" "advancing height ok"
# 分叉:同高度不同hash → 判失败
oracle_fork_decide 100 0xAA 100 0xBB && r=pass || r=fork
assert_eq "fork" "$r" "fork detected"
# 同高度同hash → 判通过(防止"无条件判分叉"的退化实现骗过测试)
oracle_fork_decide 100 0xAA 100 0xAA && r=pass || r=fork
assert_eq "pass" "$r" "same hash at same height ok"
# 不同高度、不同hash → 判通过(分叉只看同高度)
oracle_fork_decide 100 0xAA 101 0xBB && r=pass || r=fork
assert_eq "pass" "$r" "different height not a fork"
# stateRoot 不一致 → 判失败
oracle_stateroot_decide 0xR1 0xR2 && r=pass || r=diverge
assert_eq "diverge" "$r" "stateroot divergence detected"
oracle_stateroot_decide 0xR1 0xR1 && r=pass || r=diverge
assert_eq "pass" "$r" "equal stateroot ok"
assert_done
