#!/usr/bin/env bash
# Run a FISCO-BCOS module unit-test binary (or a single case) and report pass/fail.
# This is the Bucket C fallback: when a P2P/consensus attack can't be injected black-box,
# the fix's own decode/verify UT is real (if not black-box) evidence.
#
# Usage:
#   run_ut.sh <module> [boost-test-args...]
#     <module>  short name, e.g.  gateway | txpool | pbft | sync | tars-protocol | codec | rpc
#     extra args are passed through to the Boost.Test binary, e.g.:
#       run_ut.sh gateway --run_test=GatewayMessageTest
#       run_ut.sh tars-protocol --run_test=New1_Web3TxHashCanonicalTest --log_level=all
#
# Env:
#   BUILD_DIR   build tree to search (default: build under repo root)
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: run_ut.sh <module> [boost-test-args...]" >&2; exit 2; }
MODULE="$1"; shift

find_repo_root() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/tools/BcosAirBuilder/build_chain.sh" ] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}
REPO_ROOT="$(find_repo_root)" || { echo "ERROR: not inside a FISCO-BCOS checkout" >&2; exit 1; }
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"

# Preferred conventional path, then a broad find fallback.
BIN="$BUILD_DIR/bcos-$MODULE/test/test-bcos-$MODULE"
if [ ! -x "$BIN" ]; then
  BIN="$(find "$BUILD_DIR" -type f -name "test-bcos-$MODULE" 2>/dev/null | head -1 || true)"
fi
[ -n "${BIN:-}" ] && [ -x "$BIN" ] || {
  echo "ERROR: UT binary test-bcos-$MODULE not found under $BUILD_DIR." >&2
  echo "       Build it, e.g.:  cmake --build $BUILD_DIR --target test-bcos-$MODULE -j" >&2
  echo "       Available test binaries:" >&2
  find "$BUILD_DIR" -type f -name 'test-bcos-*' 2>/dev/null | sed 's/^/         /' >&2
  exit 1
}

# Run from the working directory CMake registers for these tests, not from wherever the caller
# happens to stand. cmake/SearchTestCases.cmake's config_test_cases() passes
# <source>/<module>/test/unittests as each case's WORKING_DIRECTORY, and several suites load
# fixtures by relative path from there — bcos-gateway's config tests read both
# "data/config/config_ipv4.ini" AND "../../../bcos-gateway/test/unittests/data/config/..."; only
# that one directory satisfies both. Run from the repo root instead and the binary reports 11
# failures; from build/<module>/test, 7; from here, none. A gate that fails on the caller's CWD is
# a false alarm, and a gate that cries wolf gets ignored as surely as one that stays green.
# Both spellings are in use in this tree: most modules keep their cases in test/unittests,
# bcos-executor in test/unittest (singular). Fall back to the binary's own directory for anything
# that matches neither.
RUN_DIR="$REPO_ROOT/bcos-$MODULE/test/unittests"
[ -d "$RUN_DIR" ] || RUN_DIR="$REPO_ROOT/bcos-$MODULE/test/unittest"
[ -d "$RUN_DIR" ] || RUN_DIR="$(dirname "$BIN")"

echo ">> running $BIN ${*:-(all cases)}  (cwd $RUN_DIR)"
if ( cd "$RUN_DIR" && "$BIN" "$@" ); then
  echo ">> UT PASS  (module=$MODULE${*:+ , args=$*})  — record as UT-only evidence in the matrix"
else
  rc=$?
  echo ">> UT FAIL  (module=$MODULE, exit=$rc)" >&2
  exit $rc
fi
