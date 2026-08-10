---
name: fisco-bcos-release-gate
description: >-
  Run a release gate against FISCO-BCOS (AIR mode) that reproduces a production chain's exact
  config profile locally, replays it through four gate scenario families, and judges the result
  under three failure oracles (crash / consensus-halt / state-mismatch), recording any defect
  found. Use this skill WHENEVER the user wants to run a release gate, continuously loop-test a
  build, regression-test before shipping, reproduce a production config profile locally, replay a
  captured profile, test an upgrade path before rollout, validate a release candidate, or run one
  round of the gate — even if they don't say the word "skill" or "gate". Triggers on: "发布门禁",
  "release gate", "持续循环测试", "回归测试", "生产配置复现", "profile 回放", "升级路径测试",
  "发布前验证", "跑一轮门禁".
---

# FISCO-BCOS Release Gate

## Step 0: 框定

This skill has two legs that run independently — decide which one the request maps to before
doing anything else:

1. **Deterministic gate** — `scripts/gate.sh`. Pure bash, no model in the loop, zero cloud
   dependency (it only ever writes a local `failures.jsonl` — see 报告 below). It is what a
   Linux cron/systemd timer runs 24×7 unattended. Its exit code is the ship/no-ship signal: 0 =
   clean, non-zero = an oracle tripped or a scenario failed.
2. **Model-exploration layer** — this skill's own workflow (Step 6, 探索层), invoked by Claude
   Code on demand or on a schedule. It hunts for what the fixed scenario families didn't think to
   test, delegating the actual attack mechanics to the sibling `fisco-bcos-testing` and
   `fisco-bcos-vuln-hunt` skills. It costs tokens and is capped by a budget, so it never substitutes
   for the deterministic leg — it only runs after that leg is clean.

Route the request:

- "跑一轮门禁" / "regression-test before shipping" / "reproduce a profile locally" → drive
  `gate.sh` directly (Steps 1–5), report the result.
- "升级路径测试" for the production profile specifically → Step 4's upgrade-scenario special
  case.
- "持续循环测试" / "找没想到的问题" / anything asking to go beyond the fixed scenarios → `gate.sh`
  first as a clean baseline, then Step 6 (探索层).

**Requires bash 4+** end to end — every script under `scripts/` checks `BASH_VERSINFO[0]` up
front and fails with an explicit message (not a cryptic `declare -gA` parse error) on stock macOS
bash 3.2; `brew install bash` first on macOS.

**Not tested / out of scope** (do not present any of these as covered): sharding execution (DAG
is tested, sharding is not), TiKV storage (RocksDB + `key_page_size=0` only), Pro/Max deployment
(Air only), and a log-grep-for-`ERROR` oracle (deliberately excluded — see 三 oracle).

## 加载 profile

`profiles/` holds 6 hand-maintained `.profile` files, parsed by `scripts/profile_lib.sh`'s
`profile_load` into 4 sections: `[meta]` / `[genesis]` / `[system_config_replay]` /
`[config_ini_override]`.

| profile | represents | what makes it distinct |
|---|---|---|
| `production-enterprise` | the one real captured production snapshot — the anchor | only profile with a real `[meta] source_chain`; only one that gets the full upgrade timeline (Step 4) and the exploration layer (Step 6) |
| `sm-gov` | SM-crypto / regulated deployment | `p2p.sm_ssl` / `rpc.sm_ssl` + SM cert paths in `[config_ini_override]` |
| `rpbft-scale` | large multi-node rPBFT | `feature_rpbft` + tree-topology sync settings |
| `default-latest` | fresh open-source install | empty `[system_config_replay]`, genesis pinned to the current latest compat version |
| `evm-full` | Ethereum-compatible / L2 use | all `feature_evm_*` flags on |
| `upgrade-legacy` | long-distance upgrade | genesis frozen at an old `compatibility_version` (e.g. 3.0.x) |

Pick the profile from what the user describes — name it explicitly if given, otherwise infer from
the axis they mention ("国密" → `sm-gov`, "老链升级" → `upgrade-legacy`) and fall back to
`production-enterprise` as the default anchor when nothing narrows it down.

**Maintenance is manual, not automated.** `production-enterprise` must be hand-re-captured
(`listSystemConfigs` via console + the node's `config.ini`) whenever the real production chain's
config drifts; the other 5 archetypes need hand-updates when a new feature/consensus/storage
option appears in the codebase that they should represent. There is no drift-detection step —
treat a stale profile as a known, accepted cost (see the profile's own `[meta] captured_at`).

## apply_profile 回放

`scripts/apply_profile.sh -p <profile> [-o outdir] [--dry-run]` replays a captured profile onto a
local AIR cluster. The mechanism matters: production feature flags are turned on **live**, at
specific block heights, via `setSystemConfigByKey` — they are not creation-time genesis constants.
Reproducing a profile therefore means replaying those activation calls, not generating a matching
genesis and calling it done.

Real-run, 4 steps:

1. `cluster_up.sh` (sibling `fisco-bcos-testing` skill) — `build_chain` + `start_all`, waits for
   RPC. Default ports from `build_chain`: P2P 30300, BCOS RPC 20200 (node`<i>` at `20200+i`), Web3
   RPC 8545 — a profile's `[config_ini_override]` can override the Web3 port (e.g.
   `web3_rpc.listen_port`).
2. Patches each node's `config.ini` per `[config_ini_override]`.
3. `stop_all.sh` + `start_all.sh` so the `config.ini` patch takes effect.
4. Replays every `[system_config_replay]` pair, one `console.sh setSystemConfigByKey <key>
   <value>` call at a time.

`--dry-run` prints the resolved plan (the `build_chain` invocation, the `config.ini` patch lines,
the `setSystemConfigByKey` lines) with no chain touched — use it to sanity-check a profile before
spending a real cluster bring-up.

**Known gap** (documented in `apply_profile.sh`'s own real-run step 1): `cluster_up.sh` has no
`compatibility_version` passthrough to `build_chain -v` yet, so a profile's `[genesis]
compatibility_version` is not actually applied at genesis time in the current wiring — the local
chain starts at `build_chain`'s own default and only reaches the profile's genesis version once a
later `setSystemConfigByKey` call bumps it (which the upgrade scenario's T5 step does explicitly —
see Step 4).

## gate 场景族(四个) + `upgrade`(独立入口)

`scripts/gate.sh -p <profile> [--scenarios a,b,c] [--dry-run]` is the orchestrator: bring up the
cluster via `apply_profile.sh`, run a baseline oracle pass, run each requested scenario family in
turn (oracle pass after each), tear down, aggregate one exit code — any oracle trip OR any
scenario failure makes the whole round non-zero.

Four scenario families make up `GATE_KNOWN_SCENARIOS` in `gate.sh` (each lives in
`scripts/scenarios/scenario_<name>.sh` and self-registers into `GATE_SCENARIOS[<name>]` when
`gate.sh` sources every file under `scripts/scenarios/`), plus a fifth self-registering script,
`scenario_upgrade.sh`, that is deliberately excluded from `GATE_KNOWN_SCENARIOS`:

| name | file | what it does | primary oracle |
|---|---|---|---|
| `ut` | `scenario_ut.sh` | runs every built module's UT binary via the sibling `fisco-bcos-testing` skill's `run_ut.sh` | crash (exit code) |
| `dual_rpc` | `scenario_dual_rpc.sh` | deploys + calls a minimal contract through both BCOS RPC (:20200, tars/console) and Web3 RPC (:8545, curl + RLP), then compares `stateRoot` across both paths | state-mismatch + result assertions |
| `malformed` | `scenario_malformed.sh` | byte-tampers a signed tx, injects it, asserts a *clean* rejection rather than a crash masquerading as one | crash (false-green guard) |
| `jsd` | `scenario_jsd.sh` | drives real parallel load through java-sdk-demo's three DMC transfer shapes, DAG on and off, and checks each run's balance-conservation assertion | state-mismatch (balance sum) + crash |
| `upgrade` † | `scenario_upgrade.sh` | replays the T0–T8 version-upgrade timeline: rolling binary swap, `compatibility_version` bump, bugfix-flag flip assertion | all three |

† not a `GATE_KNOWN_SCENARIOS` member — selecting it via `--scenarios upgrade` is a hard rejection
(exit 2; see "`upgrade` is not a gate-sweep scenario" below), not a swept family. It is a separate,
directly-invoked entry point.

**Weighting per profile** (every profile still gets all four families run for real, never a smoke
pass — `gate.sh -p <profile>` covers `ut`/`dual_rpc`/`malformed`/`jsd`; `upgrade` is driven directly per
the note below, since selecting it through `gate.sh --scenarios` is a hard rejection, not something
the bare-dispatch loop can run. The difference across profiles is depth on `upgrade` and whether the
exploration layer attaches):

- `production-enterprise`: full T0–T8 timeline against real old/new binaries, **plus** the
  exploration layer (Step 6).
- `upgrade-legacy`: its own long-distance upgrade path (frozen old genesis version → target).
- `sm-gov` / `rpbft-scale` / `default-latest` / `evm-full`: standard gate — `ut` / `dual_rpc` /
  `malformed` at full depth, `upgrade` run at that profile's own compat version, no exploration
  layer attached.

**`upgrade` needs a console built against java-sdk `release-3.9.0`.** Once a profile enables
`auth_check_status`, the version bump can only go through a committee proposal, and java-sdk 3.8.0's
`AuthManager.createSetSysConfigProposal` rejects every version string it is given — its
`EnumNodeVersion` stops at 3.7.0, so 3.16.4, 3.17.0 and even its own 3.8.0 all come back
"please check valid range". Branch `release-3.9.0` replaced that with a check against the version
the chain itself reports. Build it (`git clone -b release-3.9.0 …/java-sdk && bash gradlew jar`,
JDK 8) and drop `fisco-bcos-java-sdk-3.9.0-SNAPSHOT.jar` into the console's `lib/` — also replace
the console's jackson 2.14 jars with the 2.20 ones from the SDK's own `dist/lib`, or the client
dies at startup with `NoSuchFieldError: REQUIRE_HANDLERS_FOR_JAVA8_OPTIONALS`. With that in place a
single governor at 0% thresholds makes the proposal execute immediately, and the bugfix flags flip.

**`jsd` needs `JSD_DIR` and fails without it — on purpose.** It runs java-sdk-demo's DMC transfer
demos, so it needs a built distribution: point `JSD_DIR` at a directory holding `apps/ conf/ lib/`
(java-sdk-demo's `dist/` after `bash gradlew ass`). It is pure Java, so build it anywhere with a
JDK 8/11 and copy `dist/` to the machine under test. With `JSD_DIR` unset the scenario reports FAIL
rather than skipping, for the same reason `ut` fails with no UT binaries: a release gate that
reports PASS having exercised no load has not tested anything. The scenario wires the distribution
itself (SSL off, single peer, signing account pinned to the genesis auth_admin that
`apply_profile.sh` funds) — do not hand-edit its `conf/config.toml` first.

**`upgrade` is not a gate-sweep scenario — selecting it is a usage error, on purpose.**
`scenario_upgrade_run`'s real signature is `scenario_upgrade_run <outdir> <old_bin> <new_bin>
<target_ver>`, but `gate.sh`'s real-run dispatch loop calls every registered scenario function bare
(no arguments) — it cannot supply those four. So `GATE_KNOWN_SCENARIOS` is exactly the four
runnable families (`ut dual_rpc malformed jsd`); `upgrade` is deliberately excluded from it, even
though `scenario_upgrade.sh` still self-registers into `GATE_SCENARIOS` for callers that source it
directly. `_gate_validate_scenarios` checks every requested name and rejects a bare `upgrade`
selection with exit 2 (config error) before any chain is touched — `--scenarios upgrade`, with or
without `--dry-run`, fails immediately with a message pointing at the dedicated entry point:
`fbt gate upgrade -p <profile> --old-bin <p> --new-bin <p> --target-ver <v>`. An unknown scenario
name also returns 2; a known-but-unregistered name (a `scenario_<name>.sh` that failed to source)
returns 3. This means the canonical headline command, `gate.sh -p <profile>` with no `--scenarios`
flag, runs `ut` / `dual_rpc` / `malformed` / `jsd` for real and reaches `GATE: PASS` on a healthy
chain — `upgrade` never appears in that default sweep. To actually drive the upgrade timeline,
source `scripts/scenarios/scenario_upgrade.sh` directly and call `scenario_upgrade_run` yourself
with the cluster outdir, the old (current production) binary, the new (release-candidate) binary,
and the target `compatibility_version` string.

Use `gate.sh -p <profile> --dry-run` first — it validates every requested scenario name against
`GATE_KNOWN_SCENARIOS` and prints the resolved plan with no chain touched.

The deterministic gate layer does not auto-generate pairwise or full-combinatorial profiles across
the flag space — the 6 archetypes above are hand-curated on purpose; whatever combination space
they don't cover is left to the exploration layer's random search (Step 6), not swept here.

## 三 oracle

Three failure signals, each judged by a pure decision function — `oracle_liveness_decide` /
`oracle_fork_decide` / `oracle_stateroot_decide` in `scripts/oracle_lib.sh`, and
`oracle_crash_check` in `scripts/oracle_crash.sh` itself, not `oracle_lib.sh` — fed by a
live-polling wrapper:

| oracle | wrapper | decision fn | default threshold | trips on |
|---|---|---|---|---|
| crash | `oracle_crash.sh` | `oracle_crash_check` | `RG_ONCE_WAIT_SEC`=2s (the `--once` window `gate.sh` actually uses); `RG_HANG_SEC`=10s (RPC-hang probe) applies only to `oracle_crash.sh`'s continuous-poll mode, which `gate.sh` never reaches | a node PID is gone, or a core-dump file is found |
| consensus-halt | `oracle_liveness.sh` | `oracle_liveness_decide` | `RG_STALL_SEC`=30s | block height flat for longer than the threshold while transactions are pending |
| state-mismatch | `oracle_stateroot.sh` | `oracle_stateroot_decide` | exact match, no tolerance | `stateRoot` differs across nodes at the same height |

All three run as bounded, one-shot checks — never a persistent background poller — once as a
baseline right after cluster bring-up, then again after every scenario (`gate.sh`'s
`run_oracles_once`). Any trip, on any call, fails the whole gate round and appends one row to
`failures.jsonl` (see 报告).

**GAP**: through `gate.sh`'s own sweep, only crash and consensus-halt actually get a chance to
fire for real — state-mismatch needs per-node RPC discovery that `gate.sh`'s single `-r "$RPC_URL"`
call doesn't do. See `references/oracle-detection.md`'s state-mismatch section for the mechanism
and the one place a real cross-node comparison does run today.

**Explicitly not an oracle**: grepping logs for `ERROR`. It is noisy and false-positive-prone, so
it is deliberately excluded from the pass/fail judgment — though failure evidence (including logs)
is still preserved for a human to look at when a trip does happen.

## 探索层

Attaches only to the `production-enterprise` profile, and only after `gate.sh` has already come
back clean on it — this layer looks for what the fixed scenario families didn't think to test, it
does not substitute for them.

Two search directions:

1. **Diff-aware**: diff the production binary against the release-candidate binary's source (e.g.
   `git diff <production_tag> <release_candidate_tag>`) and concentrate probing on what actually
   changed.
2. **Combinatorial divergence**: randomly flip flag combinations across the axes the 6 archetype
   profiles don't individually cover — the cross-product the deterministic layer deliberately
   leaves unswept (see the note at the end of gate 场景族).

Delegate the actual mechanics rather than reimplementing them here:

- `fisco-bcos-testing` skill — craft new transactions, byte-tamper, drive both RPC surfaces.
- `fisco-bcos-vuln-hunt` skill — Hunt → Prove against whatever surface the diff/combinatorial pass
  points at.

Every session has a token/round budget cap — stop and report at the cap rather than running
open-ended.

## 飞轮沉淀

Two directories both named "scenarios" exist in this repo — do not conflate them:

- `scripts/scenarios/` — the 5 general-purpose `scenario_*.sh` families from gate 场景族, broad
  by design, run on every gate round.
- `scenarios/` (top-level) — narrow, one-fixture-per-confirmed-failure `.case` files (INI-like:
  `[case]` `profile=` / `input=` / `expect_oracle=pass|reject`), replayed by
  `scripts/run_case.sh <case>`. See `scenarios/README.md` for the full format.

The flywheel: the exploration layer (Step 6) confirms a failure is real — not a false positive —
by hand or via `fisco-bcos-testing`/`fisco-bcos-vuln-hunt`; that confirmed `profile` + exact
reproducing `input` + `expect_oracle` gets distilled into a `.case` file dropped into `scenarios/`,
where it becomes a permanent regression fixture.

**Current wiring, stated accurately, not aspirationally**: `gate.sh` does **not** currently sweep
`scenarios/*.case` automatically — its scenario-sourcing loop only globs `scripts/scenarios/*.sh`.
So today, "the gate re-runs it every round" means invoking `run_case.sh` on each accumulated
`.case` yourself as part of a gate round; wiring an automatic `.case` sweep into `gate.sh` is a
known next step, not yet implemented. Do not report `gate.sh` as auto-replaying `scenarios/*.case`.

## 报告

At the end of a gate round (or an exploration session), assemble:

- **Evidence matrix**: which profile × scenario-family × oracle combinations ran, pass/fail per
  cell.
- **Run record**: cluster outdir, node PIDs, RPC URLs used, and whether it was `--dry-run` or a
  real run.
- **Defect logging**, local first, cloud second — matching the split baked into the scripts so the
  deterministic leg never touches the network:
  1. `gate.sh` already writes local defects as it runs: every oracle trip is appended to
     `<cluster_outdir>/failures.jsonl` via `scripts/failures_lib.sh`'s `failures_append`
     (profile/scenario/oracle/severity/desc/repro/evidence/version, `reported:false`). Pure local
     file I/O, zero network.
  2. As the model-layer report step, run `scripts/report_defects.sh <outdir>` (add `--dry-run`
     first to preview the payload and record count without writing). It reads the unreported rows
     out of `failures.jsonl` and syncs them to the Tencent smartsheet defect ledger
     (`file_id=ZgGaGJqoseMl`, `sheet_id=t00i2h`) via the `tencent-docs` skill's `mcporter call
     tencent-docs smartsheet.add_records`, then marks those rows `reported:true` with their
     `record_id` locally so the same defect is never pushed twice.

## Bundled resources

| File | When to read |
|------|--------------|
| `scripts/apply_profile.sh` | replay a captured `.profile` onto a local AIR cluster |
| `scripts/gate.sh` | the deterministic-gate orchestrator: bring up cluster, run scenarios, judge oracles |
| `scripts/profile_lib.sh` | `.profile` parser (`profile_load` → `PROFILE_*` arrays) |
| `scripts/oracle_lib.sh` / `oracle_crash.sh` / `oracle_liveness.sh` / `oracle_stateroot.sh` | the three failure oracles |
| `scripts/run_case.sh` | replay one `scenarios/*.case` regression fixture |
| `scripts/failures_lib.sh` / `report_defects.sh` | local defect sink + Tencent smartsheet sync (报告) |
| `scripts/scenarios/scenario_ut.sh` / `scenario_dual_rpc.sh` / `scenario_malformed.sh` / `scenario_jsd.sh` | the four gate scenario families (gate 场景族) |
| `scripts/scenarios/scenario_upgrade.sh` | the `upgrade` timeline — a separate, directly-invoked entry point, not a `GATE_KNOWN_SCENARIOS` member |
| `profiles/*.profile` | the 6 hand-maintained config profiles (加载 profile) |
| `scenarios/*.case` | regression fixtures distilled from confirmed exploration-layer findings (飞轮沉淀) |
| `references/oracle-detection.md` | 三 oracle: decision logic, default thresholds, how to tune `RG_STALL_SEC` / `RG_ONCE_WAIT_SEC` / `RG_HANG_SEC` |
| `references/profile-authoring.md` | 加载 profile: how to hand-capture a new production `.profile` from `listSystemConfigs` + `config.genesis` + `config.ini` |
| `references/upgrade-path.md` | gate 场景族's `upgrade` row: T0-T8 operational detail, assertion points, and the `scenario_upgrade_run` arg-passing gap |
