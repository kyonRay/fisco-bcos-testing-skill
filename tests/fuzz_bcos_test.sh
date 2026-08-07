#!/usr/bin/env bash
# Hermetic unit tests for scripts/fuzz_bcos.sh's pure functions: bisection index math, the
# accept/reject/unknown response classifier, batch/seed planning, and the .case filename /
# --dry-run formatting helpers. Sourcing fuzz_bcos.sh must be side-effect-free — it guards its
# getopts parsing and live-chain batch loop behind a BASH_SOURCE!=0 check (same convention as
# scripts/oracle_liveness.sh, see tests/oracle_liveness_parse_test.sh), so this pulls in only the
# function definitions, no live IO, matching tests/scenario_malformed_test.sh's own hermetic
# pattern for the sibling directed-fuzz scenario.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/fuzz_bcos.sh

# ---------------------------------------------------------------------------
# _fuzz_batch_seed — deterministic per-batch seed (base + batch_idx).
# ---------------------------------------------------------------------------
assert_eq "42" "$(_fuzz_batch_seed 42 0)" "batch 0 seed == base seed"
assert_eq "43" "$(_fuzz_batch_seed 42 1)" "batch 1 seed == base+1"
assert_eq "142" "$(_fuzz_batch_seed 42 100)" "batch 100 seed == base+100"

# ---------------------------------------------------------------------------
# _fuzz_plan_mode — RG_FUZZ_SEC (if set and >0) takes precedence over RG_FUZZ_ITERS.
# ---------------------------------------------------------------------------
assert_eq "iters 20" "$(_fuzz_plan_mode 20 0)" "sec=0 -> iters governs"
assert_eq "iters 20" "$(_fuzz_plan_mode 20 "")" "sec unset (empty) -> iters governs"
assert_eq "sec 120" "$(_fuzz_plan_mode 20 120)" "sec>0 -> sec takes precedence over iters"

# ---------------------------------------------------------------------------
# _fuzz_classify_response — pure JSON-RPC response classifier. Rejection is the healthy path
# here (see header), so this is a classifier, not a pass/fail verdict.
# ---------------------------------------------------------------------------
assert_eq "rejected" "$(_fuzz_classify_response '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"bad tx"}}')" \
    "response with an error member classifies as rejected"
assert_eq "accepted" "$(_fuzz_classify_response '{"jsonrpc":"2.0","id":1,"result":"0xabc123"}')" \
    "response with a result member classifies as accepted"
assert_eq "unknown" "$(_fuzz_classify_response '')" \
    "empty response (curl failure/timeout) classifies as unknown, NOT accepted"
assert_eq "unknown" "$(_fuzz_classify_response 'not even json')" \
    "unparseable non-empty response classifies as unknown"

# ---------------------------------------------------------------------------
# _fuzz_tally — pure count of classifications.
# ---------------------------------------------------------------------------
assert_eq "accepted=2 rejected=1 unknown=1" "$(_fuzz_tally accepted accepted rejected unknown)" \
    "tally counts each class"
assert_eq "accepted=0 rejected=0 unknown=0" "$(_fuzz_tally)" "tally of nothing is all zero"

# ---------------------------------------------------------------------------
# _fuzz_bisect_done / _fuzz_bisect_lower_half / _fuzz_bisect_upper_half — pure bisection index
# math. Halves must cover [lo,hi] with no gap and no overlap, and must converge (mid strictly
# inside a range of size >= 2) so the caller's while-not-done loop always terminates.
# ---------------------------------------------------------------------------
if _fuzz_bisect_done 3 3; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "bisect_done: singleton range is done"
if _fuzz_bisect_done 3 5; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "bisect_done: multi-element range is not done"

assert_eq "0 4" "$(_fuzz_bisect_lower_half 0 9)" "lower half of [0,9] is [0,4]"
assert_eq "5 9" "$(_fuzz_bisect_upper_half 0 9)" "upper half of [0,9] is [5,9]"
assert_eq "0 0" "$(_fuzz_bisect_lower_half 0 1)" "lower half of [0,1] is [0,0] (terminal case)"
assert_eq "1 1" "$(_fuzz_bisect_upper_half 0 1)" "upper half of [0,1] is [1,1] (terminal case)"

# No-gap/no-overlap property across a range of sizes: hi of lower half + 1 == lo of upper half.
for hi in 1 2 3 9 10 99 100; do
    read -r llo lhi <<< "$(_fuzz_bisect_lower_half 0 "$hi")"
    read -r ulo uhi <<< "$(_fuzz_bisect_upper_half 0 "$hi")"
    assert_eq "0" "$llo" "lower half of [0,$hi] starts at 0"
    assert_eq "$hi" "$uhi" "upper half of [0,$hi] ends at $hi"
    assert_eq "$((lhi + 1))" "$ulo" "halves of [0,$hi] partition with no gap/overlap"
done

# ---------------------------------------------------------------------------
# _fuzz_case_filename — single source of truth for a distilled case's filename.
# ---------------------------------------------------------------------------
assert_eq "fuzz_seed42_idx7.case" "$(_fuzz_case_filename 42 7)" "case filename encodes seed and idx"

# ---------------------------------------------------------------------------
# _fuzz_print_dry_plan — pure formatting, no IO (the only live-touching parts of fuzz_bcos.sh are
# gated behind the BASH_SOURCE!=0 execution guard, which sourcing this file never crosses).
# ---------------------------------------------------------------------------
out="$(_fuzz_print_dry_plan 42 20 0 100 both)"
assert_contains "$out" "base_seed=42" "dry plan reports the base seed"
assert_contains "$out" "iteration count, 20 batches" "dry plan reports iters mode when sec=0"
assert_not_contains "$out" "ERROR" "dry plan never touches a live chain"

out_sec="$(_fuzz_print_dry_plan 42 20 120 100 both)"
assert_contains "$out_sec" "wall-clock, 120s" "dry plan reports sec mode when RG_FUZZ_SEC>0"

# ---------------------------------------------------------------------------
# _fuzz_should_bisect — pure RG_FUZZ_RESTART_CMD gating decision (Bug 2). Bisecting a genuine
# crash (pids actually dead) with no restart command is meaningless — every probe would trip the
# oracle regardless of which input was the culprit, since the node never comes back up between
# probes. That is the ONE combination this must refuse; everything else proceeds.
# ---------------------------------------------------------------------------
if _fuzz_should_bisect 0 1; then rc=0; else rc=1; fi
assert_eq "1" "$rc" "should_bisect: crash trip + no restart cmd -> SKIP bisection (dead node, can't be re-probed)"

if _fuzz_should_bisect 1 1; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "should_bisect: crash trip + restart cmd configured -> bisect (each probe restarts first)"

if _fuzz_should_bisect 0 0; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "should_bisect: liveness-only halt (pids alive), no restart cmd -> bisect anyway (node still probeable)"

if _fuzz_should_bisect 1 0; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "should_bisect: liveness-only halt + restart cmd configured -> bisect"

# ---------------------------------------------------------------------------
# _fuzz_bisect stdout purity (Bug 1 regression). The real bug: oracle_crash.sh/oracle_liveness.sh
# print human-readable lines (e.g. "CRASH: pid <N> is gone") to THEIR OWN stdout, and those lines
# leaked into _fuzz_bisect's command-substituted return value, turning `range="$(_fuzz_bisect ...)"`
# into garbage ("CRASH: pid 3972304 is gone ...") instead of "lo hi" — which then blew up
# downstream with "pid: unbound variable". _fuzz_bisect takes an injectable probe_fn (5th arg)
# specifically so this is testable without a live chain: a mock probe that deliberately prints
# noise to stdout AND signals its verdict via exit code must NOT be able to pollute _fuzz_bisect's
# own captured stdout, no matter what it prints — this is enforced by the explicit `>&2` redirect
# on every probe_fn call site inside _fuzz_bisect, not by trusting the probe to behave.
# ---------------------------------------------------------------------------
_MOCK_CULPRIT=7
_mock_probe_noisy() {
    # Prints exactly the kind of noise the real bug leaked (oracle_crash.sh's own wording) to
    # STDOUT, then signals "reproduces" (exit 0) only when the culprit idx falls in [lo,hi].
    local lo="$3" hi="$4"
    echo "CRASH: pid 3972304 is gone"
    echo "some other human-readable oracle chatter"
    [[ "$lo" -le "$_MOCK_CULPRIT" && "$_MOCK_CULPRIT" -le "$hi" ]]
}

range="$(_fuzz_bisect 42 both 0 9 _mock_probe_noisy)"
assert_eq "7 7" "$range" "bisect isolates culprit idx 7 via a noisy mock probe"
if [[ "$range" =~ ^[0-9]+\ [0-9]+$ ]]; then rc=0; else rc=1; fi
assert_eq "0" "$rc" "bisect's captured stdout is EXACTLY two integers — no leaked 'CRASH: pid ...' noise (the actual bug)"

# ---------------------------------------------------------------------------
# _fuzz_bisect ABORT propagation (Bug 2 mechanism). When the restart-aware probe cannot confirm
# the cluster is healthy again (RG_FUZZ_RESTART_CMD failed, or was never configured for a genuine
# crash), it must signal a hard ABORT (exit 2) — distinct from "clean" (1) — and _fuzz_bisect must
# stop immediately rather than keep looping against a cluster it can no longer trust the state of.
# ---------------------------------------------------------------------------
# NOTE: _fuzz_bisect runs inside a `$(...)` command substitution below, i.e. in a SUBSHELL — a
# plain shell variable the mock increments would not survive back to this (parent) shell. Use a
# temp file as the call counter instead; file writes do cross the subshell boundary.
_abort_probe_callfile="$(mktemp)"
_mock_probe_abort() {
    echo x >> "$_abort_probe_callfile"
    echo "noise from an aborting probe"
    return 2
}
bisect_rc=0
range="$(_fuzz_bisect 42 both 0 9 _mock_probe_abort)" || bisect_rc=$?
assert_eq "2" "$bisect_rc" "bisect propagates ABORT (rc=2) when the probe cannot confirm cluster health"
assert_eq "0 9" "$range" "bisect's stdout on abort is still exactly the range it was working on, no noise leaked"
abort_probe_calls="$(wc -l < "$_abort_probe_callfile" | tr -d ' ')"
assert_eq "1" "$abort_probe_calls" "bisect stops immediately on ABORT — does not keep probing a cluster it can't trust"
rm -f "$_abort_probe_callfile"

# ---------------------------------------------------------------------------
# _fuzz_reinject_range_and_check probe-POLARITY regression (the live-bisection bug this skill
# actually shipped: this real probe used to end with a bare `_fuzz_oracle_check_once ...` call and
# let ITS exit code fall through — 0 = all oracles clean. But _fuzz_bisect (and every mock probe
# above) assumes the OPPOSITE convention: 0 = trip REPRODUCED in this range. That inversion made
# bisection recurse into whichever half was actually CLEAN and converge on a non-crashing idx
# instead of the real crasher — confirmed live (idx11 crashes a clean cluster instantly; bisection
# reported idx15, a clean TarsDecodeException). The 52 earlier asserts in this file all passed
# because every mock probe used the correct polarity by construction — nothing exercised the REAL
# probe function itself. This section closes exactly that gap: drive the real
# _fuzz_reinject_range_and_check with a mocked _fuzz_oracle_check_once (its only remaining IO
# dependency once JAVA_BIN is stubbed to a no-op) and assert its return polarity directly.
# ---------------------------------------------------------------------------
# `true -jar ... fuzz ...` ignores its args and prints nothing to stdout, so the inject loop
# inside _fuzz_reinject_range_and_check runs zero iterations — no live java/chain needed, and
# _fuzz_inject_and_classify is never actually invoked. This override only affects code below it
# (bash executes top-to-bottom; nothing earlier in this file depends on a real JAVA_BIN).
JAVA_BIN=true

# Case A: oracles clean (matches _fuzz_oracle_check_once's own 0=clean convention).
_fuzz_oracle_check_once() { return 0; }
probe_rc=0
_fuzz_reinject_range_and_check 42 both 0 4 || probe_rc=$?
assert_eq "1" "$probe_rc" \
    "real probe: oracles CLEAN -> returns 1 (did NOT reproduce), matching _fuzz_bisect's contract"

# Case B: an oracle tripped.
_fuzz_oracle_check_once() { return 1; }
probe_rc=0
_fuzz_reinject_range_and_check 42 both 0 4 || probe_rc=$?
assert_eq "0" "$probe_rc" \
    "real probe: oracle TRIPPED -> returns 0 (reproduced), matching _fuzz_bisect's contract"

assert_done
