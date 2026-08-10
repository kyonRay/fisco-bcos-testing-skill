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
# _fuzz_case_filename — single source of truth for a distilled case's filename. transport defaults
# to "bcos" (unset RG_FUZZ_TRANSPORT / default) and must reproduce the ORIGINAL filename exactly —
# only "web3" changes the name, so an existing BCOS case's identity never changes.
# ---------------------------------------------------------------------------
assert_eq "fuzz_seed42_idx7.case" "$(_fuzz_case_filename 42 7)" "case filename encodes seed and idx (2-arg call, unchanged from before the transport switch)"
assert_eq "fuzz_seed42_idx7.case" "$(_fuzz_case_filename 42 7 bcos)" "case filename: explicit bcos transport matches the default"
assert_eq "fuzz_web3_seed42_idx7.case" "$(_fuzz_case_filename 42 7 web3)" "case filename: web3 transport gets a distinguishing fuzz_web3_ prefix"
assert_eq "fuzz_ethmethod_seed7_idx3.case" "$(_fuzz_case_filename 7 3 web3method)" "case filename: web3method transport gets a distinguishing fuzz_ethmethod_ prefix (Entry 4)"

# ---------------------------------------------------------------------------
# _fuzz_generator_subcommand — which tamper-fuzz-all.jar subcommand a transport drives.
# ---------------------------------------------------------------------------
assert_eq "fuzz" "$(_fuzz_generator_subcommand bcos)" "generator subcommand: bcos -> fuzz"
assert_eq "web3fuzz" "$(_fuzz_generator_subcommand web3)" "generator subcommand: web3 -> web3fuzz"
assert_eq "ethmethodfuzz" "$(_fuzz_generator_subcommand web3method)" "generator subcommand: web3method -> ethmethodfuzz (Entry 4)"
RG_FUZZ_TRANSPORT=bcos
assert_eq "fuzz" "$(_fuzz_generator_subcommand)" "generator subcommand: no-arg call reads RG_FUZZ_TRANSPORT (bcos)"
RG_FUZZ_TRANSPORT=web3
assert_eq "web3fuzz" "$(_fuzz_generator_subcommand)" "generator subcommand: no-arg call reads RG_FUZZ_TRANSPORT (web3)"
RG_FUZZ_TRANSPORT=web3method
assert_eq "ethmethodfuzz" "$(_fuzz_generator_subcommand)" "generator subcommand: no-arg call reads RG_FUZZ_TRANSPORT (web3method)"
# Reset to the script's own default (NOT unset — fuzz_bcos.sh runs under `set -u`, and later code
# in this file, e.g. _fuzz_reinject_range_and_check below, reads RG_FUZZ_TRANSPORT indirectly via
# _fuzz_generator_subcommand's no-arg fallback; leaving it unbound would trip nounset there).
RG_FUZZ_TRANSPORT=bcos

# ---------------------------------------------------------------------------
# _fuzz_inject_payload_bcos / _fuzz_inject_payload_web3 / _fuzz_inject_payload_web3method — pure
# JSON-RPC payload builders. bcos/web3 wrap a bare hex; web3method is pure identity — its
# generator's own last TSV column IS already a complete JSON-RPC envelope (method varies per idx),
# so there is no wrapping left to do (see that function's own doc in fuzz_bcos.sh).
# ---------------------------------------------------------------------------
BCOS_GROUP_ID=group0
assert_eq '{"jsonrpc":"2.0","method":"sendTransaction","params":["group0","","0xdead"],"id":1}' \
    "$(_fuzz_inject_payload_bcos 0xdead)" "bcos payload: groupID/nodeName/hex triple"
assert_eq '{"jsonrpc":"2.0","method":"eth_sendRawTransaction","params":["0xdead"],"id":1}' \
    "$(_fuzz_inject_payload_web3 0xdead)" "web3 payload: single hex string in params, not a triple"
assert_eq '{"a":1}' "$(_fuzz_inject_payload_web3method '{"a":1}')" \
    "web3method payload: identity — the generator's own envelope column passes through unchanged"

# ---------------------------------------------------------------------------
# _fuzz_sq_escape — pure bash single-quote escaper (Entry 4). Load-bearing for the web3method
# .case `input =` line: the bytes strategy emits arbitrary characters including raw `'`, and this
# is the ONLY thing standing between that and a corrupted/unparseable distilled .case.
# ---------------------------------------------------------------------------
assert_eq "a'\\''b" "$(_fuzz_sq_escape "a'b")" "sq_escape: a single embedded quote becomes the '\\'' idiom"
assert_eq "no_quotes_here" "$(_fuzz_sq_escape "no_quotes_here")" "sq_escape: no embedded quote is a no-op"
assert_eq "'\\''start" "$(_fuzz_sq_escape "'start")" "sq_escape: quote at the very start is escaped too"
assert_eq "end'\\''" "$(_fuzz_sq_escape "end'")" "sq_escape: quote at the very end is escaped too"

# ---------------------------------------------------------------------------
# _fuzz_inject_curl_cmd — the exact curl command a distilled .case's `input =` line records. For
# the default bcos transport this must reproduce the ORIGINAL hardcoded input= line verbatim (see
# the case-writer's own doc) — a byte-for-byte non-regression check. web3method (Entry 4) is the
# odd one out: it pipes the sq-escaped envelope through stdin rather than `curl -d`, per the
# escaping design in fuzz_bcos.sh's RG_FUZZ_TRANSPORT header doc.
# ---------------------------------------------------------------------------
BCOS_RPC_URL=http://127.0.0.1:20200
RG_FUZZ_WEB3_URL=http://127.0.0.1:8545
assert_eq "curl -sS -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"sendTransaction\",\"params\":[\"group0\",\"\",\"0xdead\"],\"id\":1}' http://127.0.0.1:20200" \
    "$(_fuzz_inject_curl_cmd 0xdead bcos)" "inject curl cmd: bcos transport targets BCOS_RPC_URL with sendTransaction"
assert_eq "curl -sS -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"0xdead\"],\"id\":1}' http://127.0.0.1:8545" \
    "$(_fuzz_inject_curl_cmd 0xdead web3)" "inject curl cmd: web3 transport targets RG_FUZZ_WEB3_URL with eth_sendRawTransaction"
assert_eq "printf '%s' '{\"a\":1}' | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8545" \
    "$(_fuzz_inject_curl_cmd '{"a":1}' web3method)" "inject curl cmd: web3method pipes via stdin (--data-binary @-), not -d"
assert_eq "printf '%s' 'a'\\''b' | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8545" \
    "$(_fuzz_inject_curl_cmd "a'b" web3method)" "inject curl cmd: web3method sq-escapes an embedded single-quote in the payload"

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

# transport-aware dry plan (Entry 3): omitting the 6th arg defaults to bcos and must reproduce the
# exact preflight wording the pre-transport-switch driver printed — no behavior change for the
# default path.
assert_contains "$out" "transport=bcos generator=fuzz" "dry plan (no transport arg): defaults to bcos/fuzz"
assert_contains "$out" "preflight (PIDs + BCOS RPC + baseline oracle)" "dry plan (no transport arg): BCOS preflight wording unchanged"

out_web3="$(_fuzz_print_dry_plan 42 20 0 100 both web3)"
assert_contains "$out_web3" "transport=web3 generator=web3fuzz" "dry plan (web3 transport): reports web3fuzz generator"
assert_contains "$out_web3" "eth_sendRawTransaction" "dry plan (web3 transport): reports the eth_sendRawTransaction inject target"
assert_contains "$out_web3" "preflight (PIDs + Web3 RPC + baseline oracle)" "dry plan (web3 transport): Web3 RPC preflight wording"
assert_not_contains "$out_web3" "ERROR" "dry plan (web3 transport): never touches a live chain either"

# web3method dry plan (Entry 4): must name the ethmethodfuzz generator and the SAME Web3 RPC /
# eth_chainId preflight web3 uses (both inject against and are oracle-polled via RG_FUZZ_WEB3_URL).
out_web3method="$(_fuzz_print_dry_plan 42 20 0 100 both web3method)"
assert_contains "$out_web3method" "transport=web3method generator=ethmethodfuzz" "dry plan (web3method transport): reports the ethmethodfuzz generator"
assert_contains "$out_web3method" "preflight (PIDs + Web3 RPC + baseline oracle)" "dry plan (web3method transport): reuses the Web3 RPC / eth_chainId preflight wording"
assert_not_contains "$out_web3method" "ERROR" "dry plan (web3method transport): never touches a live chain either"

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
# _fuzz_oracle_check_once REAL stateroot rc=3 -> exit 1 termination (review fix, sub0 task 2).
# Every other test in this file that touches _fuzz_oracle_check_once stubs the WHOLE function
# (Case A/B below, e.g.) — none of them exercise its real body, so the single most safety-critical
# behavior this task added (an infrastructure failure terminating the entire fuzz run immediately,
# rather than being folded into the ordinary trip/bisect machinery) had zero coverage. This drives
# the REAL function: a genuine single-node NODE_DIR makes _discover_stateroot_urls (and therefore
# _run_stateroot_oracle) really return rc=3, and the assertion is that the subshell running
# _fuzz_oracle_check_once exits 1 — i.e. the function's own `exit 1` fired, not a return value a
# caller could catch and reinterpret. MUST run before the Case A/B section below, which redefines
# _fuzz_oracle_check_once as a mock for the rest of the file.
# ---------------------------------------------------------------------------
_rc3_tmpdir="$(mktemp -d)"
mkdir -p "$_rc3_tmpdir/node0"
printf '[web3_rpc]\n enable=true\n listen_port=8545\n' > "$_rc3_tmpdir/node0/config.ini"
# Only one node dir under $_rc3_tmpdir -> _discover_stateroot_urls finds exactly 1 URL, which is
# <2, so it (and _run_stateroot_oracle wrapping it) returns rc=3 for real — no STATEROOT_ORACLE
# stub needed, since rc=3 short-circuits before oracle_stateroot.sh is ever invoked (same
# short-circuit tests/run_stateroot_oracle_test.sh's own "single node -> infra 3" case proves).
NODE_DIR="$_rc3_tmpdir"

# Stub ONLY the crash/liveness legs' scripts (via a fake SCRIPT_DIR), not _fuzz_oracle_check_once
# itself: both must report clean so the subshell's exit status can ONLY come from the stateroot
# leg's real `exit 1` — otherwise the liveness leg alone tripping (no live chain to poll) would
# make the subshell exit 1 anyway and the assertion below would pass even with `exit 1` neutered,
# which is exactly the false-confidence gap this test exists to close.
_rc3_scriptdir="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_rc3_scriptdir/oracle_crash.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_rc3_scriptdir/oracle_liveness.sh"
chmod +x "$_rc3_scriptdir/oracle_crash.sh" "$_rc3_scriptdir/oracle_liveness.sh"
_rc3_orig_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="$_rc3_scriptdir"
NODE_PIDS=()                            # crash leg's stub ignores its args entirely; just needs to be a declared array
_fuzz_rpc_height() { echo 5; }          # stub ONLY the height reader (still real IO otherwise) so the
                                         # function reaches the stateroot leg without a live chain to ask for a height
rc3_subshell_rc=0
( _fuzz_oracle_check_once "batch0" >/dev/null 2>&1 ) || rc3_subshell_rc=$?
assert_eq "1" "$rc3_subshell_rc" \
    "_fuzz_oracle_check_once: REAL stateroot rc=3 (<2 node RPCs discovered) terminates the run via exit 1, not a caught return value"
unset -f _fuzz_rpc_height
SCRIPT_DIR="$_rc3_orig_script_dir"
rm -rf "$_rc3_tmpdir" "$_rc3_scriptdir"

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

# ---------------------------------------------------------------------------
# _fuzz_write_case transport-awareness (Entry 3). The distilled .case's `input =` line must record
# the right RPC call for the transport that actually found the trip — a bcos case must reproduce
# the ORIGINAL hardcoded input= line byte-for-byte (no regression), a web3 case must record
# eth_sendRawTransaction against RG_FUZZ_WEB3_URL instead.
# ---------------------------------------------------------------------------
_case_tmpdir="$(mktemp -d)"
_fuzz_write_case "$_case_tmpdir/bcos.case" "profiles/production-enterprise.profile" "0xdead" 42 7 bcos >/dev/null 2>&1
bcos_case_input="$(grep '^input = ' "$_case_tmpdir/bcos.case")"
assert_eq "input = curl -sS -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"sendTransaction\",\"params\":[\"group0\",\"\",\"0xdead\"],\"id\":1}' http://127.0.0.1:20200" \
    "$bcos_case_input" "written .case (bcos): input= line matches the original hardcoded sendTransaction curl exactly"

_fuzz_write_case "$_case_tmpdir/web3.case" "profiles/production-enterprise.profile" "0xdead" 42 7 web3 >/dev/null 2>&1
web3_case_input="$(grep '^input = ' "$_case_tmpdir/web3.case")"
assert_eq "input = curl -sS -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"0xdead\"],\"id\":1}' http://127.0.0.1:8545" \
    "$web3_case_input" "written .case (web3): input= line uses eth_sendRawTransaction against RG_FUZZ_WEB3_URL"
rm -rf "$_case_tmpdir"

assert_done
