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

# expect_oracle=reject 应被解析器接受（pass|reject 是唯一合法取值 — 见 coordinator 的语义对齐裁决）
cat > "$tmp_case" <<'EOF'
[case]
profile = profiles/default-latest.profile
input = curl -sS -m 10 -d '{"bad":true}' http://127.0.0.1:8545
expect_oracle = reject
EOF
out="$(bash scripts/run_case.sh --dry-run "$tmp_case")"
assert_contains "$out" "expect_oracle: reject" "dry-run echoes expect_oracle=reject"

# 未知 expect_oracle 取值（例如旧模型残留的 crash/consensus_halt/state_mismatch）应报错非0
cat > "$tmp_case" <<'EOF'
[case]
profile = profiles/default-latest.profile
input = console.sh call HelloWorld get
expect_oracle = crash
EOF
bash scripts/run_case.sh --dry-run "$tmp_case" >/dev/null 2>&1 && r=0 || r=1
assert_eq "1" "$r" "unknown expect_oracle value (crash) rejected — pass|reject only"

assert_done
