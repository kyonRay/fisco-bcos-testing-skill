# Upgrade path — T0-T8 operational detail

`scripts/scenarios/scenario_upgrade.sh` replays the release doc's version-upgrade timeline
(`operation_and_maintenance/upgrade.md`; mechanism cross-referenced against the sibling
`fisco-bcos-testing` skill's `references/version-upgrade.md`) against a locally-reproduced copy of
`profiles/production-enterprise.profile`. This doc is the operational detail SKILL.md's gate 四场景族
table only summarizes as one row — read the script itself (`scenario_upgrade_run`, `_upg_dry`) for
anything not covered here.

## Args: the model supplies them, `gate.sh` does not

`scenario_upgrade_run`'s real signature is:

```
scenario_upgrade_run <outdir> <old_bin> <new_bin> <target_ver>
```

**`gate.sh`'s real-run scenario dispatch loop calls every registered function bare — `"$fn"` with
zero arguments** (see `gate.sh`'s dispatch loop). `scenario_upgrade_run` defaults all four params
to empty/`.` and, outside `SCENARIO_DRY=1`, immediately fails the missing-arg check — the bare loop
has no way to supply `<old_bin>`/`<new_bin>`/`<target_ver>`. So `GATE_KNOWN_SCENARIOS` excludes
`upgrade` entirely, and `_gate_validate_scenarios` rejects a selected `upgrade` outright with exit
2 before any chain is touched (see also SKILL.md's "`upgrade` is not a gate-sweep scenario" note) —
this keeps the default `gate.sh -p <profile>` sweep able to reach `GATE: PASS` on a healthy chain.
**`--scenarios upgrade` through `gate.sh` never executes the T0-T8 timeline** — it is rejected
before the run starts; to actually run it, source the file directly:

```bash
source scripts/scenarios/scenario_upgrade.sh
scenario_upgrade_run ./nodes-release-gate /path/to/old/fisco-bcos /path/to/new/fisco-bcos 3.17.0
```

`old_bin`/`new_bin` must be executable paths to actual `fisco-bcos` binaries; `target_ver` must be
an `x.y.z` string that exists as a `.to = protocol::BlockVersion::V<X>_<Y>_<Z>_VERSION` entry in
`bcos-framework/bcos-framework/ledger/Features.cpp`'s `upgradeRoadmap` table — an unrecognized
version fails loudly (`_upg_target_flags` returns 1) rather than silently asserting nothing.

## The timeline

| Step | What happens | Assertion point |
|---|---|---|
| T0 | `apply_profile.sh -p profiles/production-enterprise.profile -o <outdir>` reproduces prod locally | `apply_profile.sh` exit code; scenario aborts (rc=1) on failure |
| T1 | Baseline: one bounded pass of all three oracles (`_upg_run_oracle_triad`); snapshot each target-version flag's **pre-bump** value via `getSystemConfigByKey` | any oracle trip here independently fails the whole scenario — not merely recorded for the T7 comparison |
| T2-T4 | Per node (needs ≥3 node dirs under `<outdir>/127.0.0.1`): stop → overwrite the shared binary with `new_bin` → restart → sample height+hash from the first 3 nodes' individual BCOS RPC ports → `_upg_no_fork` | same-height/different-hash across any pair of the 3 samples fails; a short/failed sample set is itself an ERROR, not a skipped-pass |
| T5 | `console.sh setSystemConfigByKey compatibility_version <target_ver>` | non-zero console exit fails the step |
| T6 | Re-read each target-version flag; `_upg_flag_flipped(before, after)` | must be `null`/empty → `1`; anything else (including "already on before") fails |
| T7 | Re-run the same oracle triad; compare against T1 | T1 pass + T7 fail = regression, fails; T1 already-failed is noted but doesn't double-fail |
| T8 | Optional rollback: swap every node back to `old_bin`, restore `[genesis] compatibility_version` from the profile | only runs if `UPGRADE_ROLLBACK=1`; otherwise printed as `SKIP`, not a failure |

## Rolling swap is real Unix semantics, not simulated

`build_chain.sh` copies **one shared binary** to `<node_dir_root>/fisco-bcos`; every node's
generated `start.sh` execs `${SHELL_FOLDER}/../fisco-bcos`. Overwriting that file's bytes does not
affect an already-running process's in-memory image — only a process (re)started after the
overwrite picks up the new binary. So "rolling per-node swap" on this single-machine AIR layout
genuinely means: overwrite the one shared file, then stop+restart only the node under test — its
still-running siblings continue on the old binary image until their own turn, exactly like a real
multi-host rolling upgrade's mixed-version window.

## Flag derivation: `Features.cpp`, not `Features.h`

`_upg_target_flags` greps `Features.cpp`'s `setUpgradeFeatures()` `upgradeRoadmap` table — the
code the node actually runs — not `Features.h`'s enum comments, which only annotate one flag
(`bugfix_auth_check`) with a version marker and would silently under-report the rest. Re-derive the
set live rather than trusting any list baked into a doc:

```bash
grep -A5 'BlockVersion::V3_17_0_VERSION,' bcos-framework/bcos-framework/ledger/Features.cpp
```

`_upg_target_flags` distinguishes three outcomes by exit code + stdout, not just "printed nothing":
`target_ver` absent from the table entirely → error, exit 1 (T6 refuses to run against an
unverifiable set); present with an empty `.flags = {}` → exit 0, empty stdout (a legitimately
flag-less release, T6 has nothing to assert and says so); present with flags → the `Flag::<name>`
list.

## `SCENARIO_DRY=1`

The only branch exercised by this repo's own tests (`tests/scenario_upgrade_test.sh`) — no live
chain in this environment. Prints the T0-T8 plan, including the live-resolved flag list for
whatever `target_ver` you pass, and returns 0 without touching a binary, console, or RPC endpoint.
Run it first to sanity-check `target_ver` resolves before spending a real cluster + two binaries.
