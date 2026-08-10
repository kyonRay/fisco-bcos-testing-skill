# Oracle detection — decision logic, thresholds, tuning

Three failure signals, each judged by a pure function in `scripts/oracle_lib.sh` (no IO — unit
tested directly by `tests/oracle_test.sh`), fed by a thin live-polling wrapper script of the same
name. The wrapper does the curl/kill -0/sleep; the pure function does the pass/fail call. Read the
wrapper before tuning its threshold — the env var only changes what the wrapper *feeds* the
decision function, never the function's own logic.

## crash — `oracle_crash.sh` / `oracle_crash_check`

`oracle_crash_check` is defined **inside** `oracle_crash.sh` itself, not `oracle_lib.sh` — it is
the one oracle whose "decision function" already does its own IO (`kill -0`, a core-dump file
stat), so there is nothing to unit-test in isolation the way the other two are.

Per PID, it checks exactly two things (see the script's own header for what it deliberately does
NOT check — no `wait`-based exit-code/SIGABRT inspection, because the node PIDs are not this
shell's children):

- `kill -0 <pid>` fails → `CRASH: pid <pid> is gone`
- a `core.<pid>`, `core`, or `/cores/core.<pid>` file exists next to it → `CRASH: core dump found`

`gate.sh` and `scenario_upgrade.sh`'s `_upg_run_oracle_triad` both call it as `oracle_crash.sh
--once <pid...>` — a **bounded** check, not the continuous poll loop at the bottom of the script.

**`--once` window**: polls every 0.1s for `RG_ONCE_WAIT_SEC` seconds (default 2). Iteration-counted
(`ticks = RG_ONCE_WAIT_SEC * 10`), not wall-clock-timed, because BSD `date` on macOS has no
sub-second precision. Widen this if a crash you expect to detect (e.g. a kill sent from an async
subshell) sometimes races past a 2s window on a loaded machine.

**`RG_HANG_SEC`** (default 10) only matters in the continuous-poll branch (`oracle_crash.sh -r
<url> -i <interval>`, no `--once`), which neither `gate.sh` nor `scenario_upgrade.sh` reaches. A
hang there is logged, not itself a crash verdict — see `rpc_liveness_probe`.

**Known gap**: a SIGABRT'd-but-unreaped zombie still answers `kill -0`, and with core dumps
disabled (`ulimit -c 0`, common in CI) there's no core file either. This oracle cannot see that
failure mode; an ASan/TSan build is the sharper tool for it.

## consensus-halt — `oracle_liveness.sh` / `oracle_liveness_decide`

```
oracle_liveness_decide <prev_height> <cur_height> <elapsed_s> <has_pending>
```

Trips (returns 1) only when **all three** hold: `has_pending == 1`, `elapsed > RG_STALL_SEC`
(default 30), `cur <= prev`. A quiescent chain with zero pending transactions and flat height is
correctly *not* a halt — the oracle only judges "stuck while there was work to do."

`has_pending` comes from `rpc_has_pending`, which probes `eth_pendingTransactions` and counts
`"hash"` occurrences (`rpc_has_pending_parse`, unit-tested directly in
`tests/oracle_liveness_parse_test.sh` without a live chain). On probe failure it defaults
`has_pending=1` — conservative, so an RPC hiccup never masks a real stall.

**Tuning `RG_STALL_SEC`**: raise it for slower scenarios (a big rolling upgrade under load) where
a legitimate multi-second pause is expected; lower it if you want the gate to flag sluggishness
that a 30s window would let slide. `gate.sh`'s own wrapper call (`oracle_liveness.sh -r
"$RPC_URL"`) takes exactly one height sample pair via the script's own `-t`/`-n` polling (default
`-t 5 -n 2`, i.e. one 5s gap) — `RG_STALL_SEC` is compared against that measured `elapsed`, not
against `-t` directly, so shortening `-n`/`-t` and expecting `RG_STALL_SEC` to still mean the same
thing is a mistake.

## state-mismatch — `oracle_stateroot.sh` / `oracle_stateroot_decide`

```
oracle_stateroot_decide <root_a> [<root_b> ...]
```

Variadic, exact-match, zero tolerance: any argument differing from the first argument trips it.
No sampling window, no retry — one height, one round of RPC reads across the given `-r` URLs, one
verdict. There is no env-var threshold to tune here by design (a stateRoot either matches or it
doesn't).

`oracle_stateroot.sh -b <height> -r <url> [-r <url> ...]` needs at least one `-r`; with only one
URL it prints `OK: only one node sampled, nothing to compare` and exits 0 — a same-node
"comparison" is not a comparison. That single-node no-op path is no longer what `gate.sh` hits in
practice: `run_oracles_once` now derives the stateroot check via `_run_stateroot_oracle` in
`oracle_lib.sh`, which first calls `_discover_stateroot_urls <node_dir>` to enumerate **every**
node under `<outdir>/127.0.0.1/node*/config.ini` whose `[web3_rpc]` is `enable=true` (deduped,
sorted, host-normalized), then feeds all of them to `oracle_stateroot.sh` as repeated `-r` flags —
so a real cross-node stateRoot comparison runs on the baseline pass and after every scenario, not
just during `scenario_upgrade.sh`'s T2-T4 timeline. `_discover_stateroot_urls` returns 3 (on
stderr) when fewer than 2 URLs are found; `gate.sh` treats that as a hard error for that oracle
pass (`rc=1`), not a silent single-node pass. `_run_stateroot_oracle` is the one shared runner
used by every call site — `gate.sh`, `run_case.sh`, `scenario_upgrade.sh`, and `fuzz_bcos.sh` all
go through it, so this fix applies uniformly rather than only to `gate.sh`.

**`oracle_fork_decide`** (same-height/different-hash, in `oracle_lib.sh`) is defined and directly
unit-tested (`tests/oracle_test.sh`) but is not currently called by any live wrapper script or
scenario — `_upg_no_fork` in `scripts/scenarios/scenario_upgrade.sh` duplicates its logic rather
than sourcing it. `scenario_upgrade.sh`'s T2-T4 per-node fork check (sampling 3 nodes' individual
BCOS RPC ports after each binary swap) remains a separate, additional multi-node check specific to
the rolling-upgrade timeline, not a substitute for the gate-wide stateroot oracle above.

**Previously a documented GAP, now fixed**: `gate.sh`'s default sweep used to pass only one `-r`
URL to the stateroot oracle (the whole-cluster `RPC_URL`), so state-mismatch never got a real
chance to fire outside `scenario_upgrade.sh`. With `_discover_stateroot_urls`/
`_run_stateroot_oracle` in place, all three oracles now get a real chance to fire on every
`gate.sh -p <profile>` round, independent of whether `scenario_upgrade.sh` is invoked at all.

## Explicitly not an oracle: grepping logs for `ERROR`

Deliberately excluded — noisy, false-positive-prone. Evidence (including logs) is still preserved
on a trip for a human to read; it is just never the pass/fail signal itself. Do not add a fourth
oracle on this basis (see the repo's scope guard).
