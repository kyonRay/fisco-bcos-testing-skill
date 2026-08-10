#!/usr/bin/env bash
# Hermetic unit tests for scripts/fuzz_bcos.sh's case-distillation writers: _fuzz_write_case (the
# heredoc that must carry status=pending and a BARE logical profile name, never a profiles/... path)
# and _fuzz_resolve_case_dir (the writable-dir resolver — FBT_STATE_CASES -> XDG_STATE_HOME ->
# HOME -> error). Pulled in via sed+eval, same hermetic convention as
# tests/run_case_resolve_test.sh — no live chain, no sourcing the whole driver's getopts/batch loop.
# Also asserts the two relabeled scenarios/*.case fixtures carry their new `status =` field.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
eval "$(sed -n '/^_fuzz_write_case()/,/^}/p' "$SD/../scripts/fuzz_bcos.sh")"
eval "$(sed -n '/^_fuzz_resolve_case_dir()/,/^}/p' "$SD/../scripts/fuzz_bcos.sh")"
_fuzz_inject_curl_cmd() { echo "curl $1"; }

# ---------------------------------------------------------------------------
# _fuzz_write_case — status=pending, bare logical profile name (no profiles/ prefix)
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
RG_FUZZ_PROFILE_NAME=production-enterprise _fuzz_write_case "$tmp/c.case" "production-enterprise" 0xd 43 11 web3method
b="$(cat "$tmp/c.case")"
assert_contains "$b" "status = pending" "pending"
assert_contains "$b" "profile = production-enterprise" "logical name"
assert_not_contains "$b" "profiles/" "no path prefix"
assert_contains "$(cat "$SD/../scenarios/example.case")" "status = example" "example labeled"
assert_contains "$(cat "$SD/../scenarios/fuzz_seed43_idx11.case")" "status = pending" "fuzz case labeled"

# ---------------------------------------------------------------------------
# _fuzz_resolve_case_dir — 4-way resolution order test. Each case runs inside its own command
# substitution subshell so unset/env overrides never leak between assertions or out to the rest of
# this test file.
# ---------------------------------------------------------------------------
assert_eq "/explicit/cases" \
    "$(FBT_STATE_CASES=/explicit/cases XDG_STATE_HOME=/xdg HOME=/home _fuzz_resolve_case_dir)" \
    "FBT_STATE_CASES wins over XDG_STATE_HOME and HOME"

assert_eq "/xdg/fbt/cases" \
    "$(unset FBT_STATE_CASES; XDG_STATE_HOME=/xdg HOME=/home _fuzz_resolve_case_dir)" \
    "XDG_STATE_HOME fallback when FBT_STATE_CASES unset"

assert_eq "/home/.local/state/fbt/cases" \
    "$(unset FBT_STATE_CASES XDG_STATE_HOME; HOME=/home _fuzz_resolve_case_dir)" \
    "HOME fallback when FBT_STATE_CASES and XDG_STATE_HOME unset"

rc=0
out="$(unset FBT_STATE_CASES XDG_STATE_HOME HOME; _fuzz_resolve_case_dir 2>/dev/null)" || rc=$?
assert_eq "1" "$rc" "all of FBT_STATE_CASES/XDG_STATE_HOME/HOME unset -> error (non-zero), not a $HOME crash"
assert_eq "" "$out" "all-unset error prints nothing on stdout"

assert_done
