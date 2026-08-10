#!/usr/bin/env bash
# Hermetic unit tests for scripts/run_case.sh's _run_case_resolve_profile: the resolver that turns
# a .case file's `profile =` field (an absolute path / a path relative to the case's own dir / a
# bare logical name) into an absolute .profile path. Pulled in via sed+eval (same convention as
# tests/fuzz_write_case_test.sh) so this stays hermetic — no live chain, no sourcing the whole
# script's getopts/real-run flow.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
eval "$(sed -n '/^_run_case_resolve_profile()/,/^}/p' "$SD/../scripts/run_case.sh")"

# bare logical name -> ${FBT_PROFILE_DIR:-<repo>/profiles}/<name>.profile
assert_eq "/pdir/production-enterprise.profile" "$(FBT_PROFILE_DIR=/pdir _run_case_resolve_profile production-enterprise /cases)" "logical name -> profile dir"

# spec containing a `/` -> resolved relative to case_dir
assert_eq "/cases/sub/x.profile" "$(_run_case_resolve_profile sub/x.profile /cases)" "relative path -> case dir"

# absolute spec (/*) -> returned as-is, NOT joined to case_dir
assert_eq "/abs/x.profile" "$(_run_case_resolve_profile /abs/x.profile /cases)" "absolute path -> as-is"

assert_done
