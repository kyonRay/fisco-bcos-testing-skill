#!/usr/bin/env bash
# Minimal shell assertion helper. Not a framework — just fail-fast asserts.
set -euo pipefail
_ASSERT_FAILS=0
assert_eq() {  # expected actual msg
    if [[ "$1" != "$2" ]]; then
        echo "FAIL: $3 — expected [$1] got [$2]" >&2; _ASSERT_FAILS=1
    else echo "ok: $3"; fi
}
assert_contains() {  # haystack needle msg
    if [[ "$1" != *"$2"* ]]; then
        echo "FAIL: $3 — [$1] does not contain [$2]" >&2; _ASSERT_FAILS=1
    else echo "ok: $3"; fi
}
assert_not_contains() {  # haystack needle msg
    if [[ "$1" == *"$2"* ]]; then
        echo "FAIL: $3 — [$1] contains [$2]" >&2; _ASSERT_FAILS=1
    else echo "ok: $3"; fi
}
assert_done() { [[ $_ASSERT_FAILS -eq 0 ]] || { echo "TESTS FAILED" >&2; exit 1; }; echo "ALL PASS"; }
