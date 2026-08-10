#!/usr/bin/env bash
# apply_profile_passthrough_test.sh — boundary tests for apply_profile.sh's two pure functions
# (_apply_profile_cluster_up_args / _apply_profile_web3_port), plus a spy test proving the REAL
# (non-dry-run) call site actually threads the profile's compatibility_version + cluster topology
# into cluster_up.sh (Task 3's -v/-n/-p/-w/-s/-e), and that a host-provided WEB3_BASE lands as -w.
#
# Own harness vars (SD/WORK/LOGFILE etc.) — deliberately not shared with apply_profile_test.sh.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"

# ---- Part 1: pure-function boundary tests (extract just the function bodies) ----
eval "$(sed -n '/^_apply_profile_cluster_up_args()/,/^}/p' "$SD/../scripts/apply_profile.sh")"
eval "$(sed -n '/^_apply_profile_web3_port()/,/^}/p' "$SD/../scripts/apply_profile.sh")"

_apply_profile_cluster_up_args "/o u t" "3.0.0" "/bin/f i" "4" "30300,20200" "18545" "1"
printf '%s\n' "${APPLY_CU_ARGS[@]}" | grep -Fxq "/o u t" && ok=1 || ok=0; assert_eq "1" "$ok" "spaced outdir one element"
assert_contains " ${APPLY_CU_ARGS[*]} " " -v 3.0.0 " "version threaded"
assert_contains " ${APPLY_CU_ARGS[*]} " " -w 18545 " "web3 base threaded"
assert_contains " ${APPLY_CU_ARGS[*]} " " -s " "SM threaded"

_apply_profile_cluster_up_args "/o" "3.0.0" "" "4" "30300,20200" "" "0"
assert_not_contains " ${APPLY_CU_ARGS[*]} " " -e " "empty fisco_bin -> no -e"
assert_not_contains " ${APPLY_CU_ARGS[*]} " " -w " "empty web3_base -> no -w"
assert_not_contains " ${APPLY_CU_ARGS[*]} " " -s " "sm_mode 0 -> no -s (also: no set -e abort on the trailing empty-conditional — the Task 3 trap)"

assert_eq "18547" "$(_apply_profile_web3_port 8545 2 18545)" "override base wins: 18545+2"
assert_eq "8547"  "$(_apply_profile_web3_port 8545 2 '')"    "no override: profile base 8545+2"

# ---- Part 2: real-code-path spy test (Design Decisions rev3 #7 / task-4 AUTHORITATIVE addition #2) ----
# Point CLUSTER_UP (apply_profile.sh's own env-override hook) at a fake recorder script and assert
# apply_profile.sh's REAL (non-dry-run) call passed -v, -n, -p, -w, -s, -e.
REPO="$SD/.."
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/fake_cluster_up.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$LOGFILE"
# Exit nonzero right after recording argv: apply_profile.sh's real-run has no live chain to bring
# up in this hermetic test, and everything this spy needs to observe (the cluster_up.sh call
# site's own argv) has already happened by this point — set -e then aborts the caller cleanly
# instead of continuing into config.ini patching against a directory that was never created.
exit 1
FAKE
chmod +x "$WORK/fake_cluster_up.sh"

LOGFILE="$WORK/argv.log"; : > "$LOGFILE"
FAKE_BIN="$WORK/fake-fisco-bcos"
OUT="$WORK/nodes-out"

set +e
CLUSTER_UP="$WORK/fake_cluster_up.sh" LOGFILE="$LOGFILE" WEB3_BASE=18545 FISCO_BIN="$FAKE_BIN" \
    bash "$REPO/scripts/apply_profile.sh" -p "$REPO/profiles/sm-gov.profile" -o "$OUT" >"$WORK/run.out" 2>&1
rc=$?
set -e

assert_eq "1" "$rc" "spy: apply_profile.sh real-run propagates the fake cluster_up.sh's exit (see $WORK/run.out on fail)"

argv_joined=" $(tr '\n' ' ' < "$LOGFILE")"
assert_contains "$argv_joined" " -v 3.16.4 " "spy: real call passed -v (sm-gov.profile genesis compat)"
assert_contains "$argv_joined" " -n 4 " "spy: real call passed -n (node_count, default 4 — sm-gov.profile has none)"
assert_contains "$argv_joined" " -p 30300,20200 " "spy: real call passed -p (default ports)"
assert_contains "$argv_joined" " -w 18545 " "spy: real call passed -w (host WEB3_BASE outranks the profile)"
assert_contains "$argv_joined" " -s " "spy: real call passed -s (sm-gov.profile sm_crypto=true)"
assert_contains "$argv_joined" " -e $FAKE_BIN " "spy: real call passed -e (host FISCO_BIN)"

assert_done
