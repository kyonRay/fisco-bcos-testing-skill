#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/scenarios/scenario_ut.sh
assert_eq "0" "$(type -t scenario_ut_run > /dev/null && echo 0 || echo 1)" "function defined"
# dry 模式只列出将跑的模块,不真跑
out="$(SCENARIO_DRY=1 scenario_ut_run /tmp/x)"
assert_contains "$out" "run_ut.sh" "delegates to run_ut.sh"
assert_done
