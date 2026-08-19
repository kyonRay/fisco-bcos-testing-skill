#!/usr/bin/env bash
# run_case_outcome_test.sh — a failing .case is a RESULT (gate_fail -> 10), never engine_error (40).
#
# The bug this pins, caught by replaying a real fixture against a real chain: run_case.sh named no
# outcome at its verdict, so the event protocol's rc fallback mapped `exit 1` to engine_error. A
# fixture that reproduced a genuine node crash -- curl exit 52, all three oracles tripping --
# reported "fbt has a bug" (40) instead of "the chain failed" (10). That is the exact
# misclassification the exit-code contract exists to prevent, in the one command whose whole job is
# replaying confirmed defects.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
REPO="$SD/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; kill %1 2>/dev/null || true' EXIT

# A hermetic engine: real run_case.sh + event_lib.sh + oracle_lib.sh, stubs for everything that
# needs a chain. The verdict logic under test is the real one.
ENG="$WORK/scripts"
mkdir -p "$ENG"
for f in run_case.sh event_lib.sh oracle_lib.sh profile_lib.sh; do cp "$REPO/scripts/$f" "$ENG/"; done
cp -r "$REPO/profiles" "$WORK/profiles"

# The stub lays out just enough of a cluster for the real code to read: node0's config.ini is where
# _primary_web3_url derives the oracle's RPC URL from.
cat > "$ENG/apply_profile.sh" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && out="$2"; shift; done
mkdir -p "$out/127.0.0.1/node0"
printf '[web3_rpc]\n    enable=true\n    listen_ip=127.0.0.1\n    listen_port=8545\n' \
    > "$out/127.0.0.1/node0/config.ini"
exit 0
STUB
# Oracles that never trip: this test is about the verdict, not about detection.
for o in oracle_crash.sh oracle_liveness.sh oracle_stateroot.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ENG/$o"
done
chmod +x "$ENG"/*.sh

OUT="$WORK/cluster"
mkdir -p "$OUT/127.0.0.1"
printf '#!/usr/bin/env bash\nexit 0\n' > "$OUT/127.0.0.1/stop_all.sh"
chmod +x "$OUT/127.0.0.1/stop_all.sh"

# run_case.sh refuses to proceed without live node PIDs under NODE_DIR. Give it one real process
# whose argv contains that path -- pgrep -f matches the full command line.
bash -c "exec -a '$OUT/127.0.0.1/node0/fisco-bcos' sleep 60" &
sleep 0.3

# expect_oracle=pass with an input that FAILS -> case_verdict says FAIL. No oracle trips, so the
# only thing being judged is how a failed verdict is reported.
cat > "$WORK/failing.case" <<CASE
[case]
status = active
profile = default-latest
input = exit 7
expect_oracle = pass
CASE

rc=0
FBT_ENGINE_SCRIPTS="$ENG" FBT_PROFILE_DIR="$WORK/profiles" RG_ONCE_WAIT_SEC=1 \
    bash "$ENG/run_case.sh" "$WORK/failing.case" -o "$OUT" \
    3>"$WORK/events.jsonl" >"$WORK/out" 2>&1 || rc=$?

ev="$(cat "$WORK/events.jsonl" 2>/dev/null || true)"
assert_contains "$(cat "$WORK/out")" "CASE: FAIL" "the case really did fail (see $WORK/out)"
assert_contains "$ev" '"outcome":"gate_fail"' \
    "a failing case is gate_fail (10, the chain failed), not engine_error (40, fbt is broken)"
assert_not_contains "$ev" '"outcome":"engine_error"' \
    "...and never reports the HOST as broken for a fixture that did its job"

# ---- the machine's fault is infra_error (30), not the host's (40) ----
# Same sweep gate.sh got: run_case.sh's failure exits all fell through to the rc fallback, so a
# cluster that would not come up, a missing apply_profile.sh and a genuine fbt bug were one number.
rm -f "$ENG/apply_profile.sh"
rc=0
FBT_ENGINE_SCRIPTS="$ENG" FBT_PROFILE_DIR="$WORK/profiles" \
    bash "$ENG/run_case.sh" "$WORK/failing.case" -o "$WORK/c2" \
    3>"$WORK/ev2.jsonl" >/dev/null 2>&1 || rc=$?
assert_contains "$(cat "$WORK/ev2.jsonl")" '"outcome":"infra_error"' \
    "a broken install is infra_error (fix the machine), not engine_error (file a bug)"

# ---- a malformed .case is the author's mistake: config_error (20) ----
printf '[case]\nstatus = active\nprofile = default-latest\nexpect_oracle = pass\n' > "$WORK/nokey.case"
rc=0
FBT_ENGINE_SCRIPTS="$ENG" FBT_PROFILE_DIR="$WORK/profiles" \
    bash "$ENG/run_case.sh" "$WORK/nokey.case" -o "$WORK/c3" \
    3>"$WORK/ev3.jsonl" >/dev/null 2>&1 || rc=$?
assert_contains "$(cat "$WORK/ev3.jsonl")" '"outcome":"config_error"' \
    "a .case missing input= is config_error: the file is the author's to fix"

assert_done
