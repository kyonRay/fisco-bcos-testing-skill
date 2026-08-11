#!/usr/bin/env bash
# tests/upgrade_swap_test.sh — Task 6: real (not dry-text) coverage of the atomic binary-swap
# helpers scenario_upgrade.sh's rolling-upgrade steps (T2-T4, T8) and T0 baseline depend on:
#   _upg_atomic_replace_binary <src> <root>        — pure file-swap primitive
#   _upg_swap_node_binary <root> <node_name> <src> — stop -> replace -> start wrapper
#   _upg_t0_apply_argv <old_bin> <profile_path> <outdir> — fills UPG_T0_ARGV / FISCO_BIN_FOR_T0
#
# Unlike scenario_upgrade_test.sh (which only exercises pure/file-read-only functions and the
# SCENARIO_DRY=1 plan-printing branch), this file drives the real swap against a throwaway
# tmpdir fixture — no live chain needed, but real cp/mv/mktemp against real files.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source scripts/scenarios/scenario_upgrade.sh

assert_eq "0" "$(type -t _upg_atomic_replace_binary > /dev/null && echo 0 || echo 1)" "_upg_atomic_replace_binary defined"
assert_eq "0" "$(type -t _upg_swap_node_binary > /dev/null && echo 0 || echo 1)" "_upg_swap_node_binary defined"
assert_eq "0" "$(type -t _upg_t0_apply_argv > /dev/null && echo 0 || echo 1)" "_upg_t0_apply_argv defined"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# _upg_atomic_replace_binary <src> <root> — real file swap, no stop/start.
# ---------------------------------------------------------------------------
root1="$tmp/root1"
mkdir -p "$root1"
printf 'OLD' > "$root1/fisco-bcos"
printf 'NEW' > "$tmp/src1"

_upg_atomic_replace_binary "$tmp/src1" "$root1"

assert_eq "NEW" "$(cat "$root1/fisco-bcos")" "atomic_replace_binary: target now holds the new content"
assert_eq "1" "$([[ -x "$root1/fisco-bcos" ]] && echo 1 || echo 0)" "atomic_replace_binary: target is executable"
assert_eq "0" "$(ls "$root1"/.fisco-bcos.* 2>/dev/null | wc -l | tr -d ' ')" "atomic_replace_binary: no .fisco-bcos.* temp file leaked"

# Mode, not just the x bit: mktemp creates 0600, so the old `chmod +x` landed on 0711 and silently
# stripped the group/other READ bits a build_chain-generated binary ships with. Asserting -x alone
# passed against that bug (exec only needs x) — this pins the actual mode. Live-observed 0755->0711
# on a real node3 swap before the fix.
_mode_of() {  # portable: GNU stat -c, BSD/macOS stat -f
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}
assert_eq "755" "$(_mode_of "$root1/fisco-bcos")" "atomic_replace_binary: target mode is 0755, not mktemp's 0600+x=0711"

# ---------------------------------------------------------------------------
# _upg_swap_node_binary <root> <node_name> <src> — order stop -> replace -> start, via fake
# stop.sh/start.sh scripts that each snapshot the binary's CURRENT content into a shared log.
# stop.sh must see OLD (replace hasn't happened yet); start.sh must see NEW (replace already
# happened) — this proves the ordering, not just that all three steps ran.
# ---------------------------------------------------------------------------
root2="$tmp/root2"
mkdir -p "$root2/node0"
printf 'OLD' > "$root2/fisco-bcos"
printf 'NEW' > "$tmp/src2"
log="$tmp/calls.log"
: > "$log"

cat > "$root2/node0/stop.sh" <<EOF
#!/usr/bin/env bash
echo "stop:\$(cat "$root2/fisco-bcos")" >> "$log"
EOF
cat > "$root2/node0/start.sh" <<EOF
#!/usr/bin/env bash
echo "start:\$(cat "$root2/fisco-bcos")" >> "$log"
EOF
chmod +x "$root2/node0/stop.sh" "$root2/node0/start.sh"

_upg_swap_node_binary "$root2" node0 "$tmp/src2" 2>/dev/null

assert_eq "$(printf 'stop:OLD\nstart:NEW')" "$(cat "$log")" "swap_node_binary: order is stop(sees OLD) -> replace -> start(sees NEW)"
assert_eq "NEW" "$(cat "$root2/fisco-bcos")" "swap_node_binary: binary ends up replaced"

# ---------------------------------------------------------------------------
# _upg_t0_apply_argv <old_bin> <profile_path> <outdir> — pure, no IO.
# ---------------------------------------------------------------------------
_upg_t0_apply_argv "/bin/oldfisco" "/abs/prof.profile" "/out"

assert_contains " ${UPG_T0_ARGV[*]} " " /abs/prof.profile " "T0 argv includes the absolute profile path"
assert_contains " ${UPG_T0_ARGV[*]} " " /out " "T0 argv includes the outdir"
assert_not_contains " ${UPG_T0_ARGV[*]} " " /bin/oldfisco " "T0 argv does NOT embed old_bin (threaded via env, not argv)"
assert_eq "/bin/oldfisco" "$FISCO_BIN_FOR_T0" "T0 baseline binary threaded via env, not argv"

assert_done
