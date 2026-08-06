#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh

out="$(bash scripts/run_case.sh --dry-run scenarios/example.case)"
assert_contains "$out" "profile: profiles/default-latest.profile" "dry-run echoes profile"
assert_contains "$out" "input: console.sh call HelloWorld get" "dry-run echoes input"
assert_contains "$out" "expect_oracle: pass" "dry-run echoes expect_oracle"

# 缺字段应报错非0（也验证 --dry-run 之前就完成解析校验，不用起链）
tmp_case="$(mktemp -t run_case_test.XXXXXX)"
trap 'rm -f "$tmp_case"' EXIT
cat > "$tmp_case" <<'EOF'
[case]
profile = profiles/default-latest.profile
input = console.sh call HelloWorld get
EOF
bash scripts/run_case.sh --dry-run "$tmp_case" >/dev/null 2>&1 && r=0 || r=1
assert_eq "1" "$r" "missing expect_oracle rejected"

assert_done
