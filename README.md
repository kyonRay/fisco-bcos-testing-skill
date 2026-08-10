# fisco-bcos-release-gate

A [Claude Code](https://claude.com/claude-code) skill that runs a release gate against
**FISCO-BCOS** (AIR mode): reproduce a production chain's exact config profile locally, replay it
through four gate scenario families, and judge the result under three failure oracles — crash,
consensus-halt, state-mismatch — recording any defect found.

It has two legs. A **deterministic gate** (`scripts/gate.sh`) — pure bash, no model in the loop,
zero cloud dependency — is what a cron/systemd timer runs unattended; its exit code is the
ship/no-ship signal. A **model-exploration layer** attaches only after that leg is clean, and only
for the `production-enterprise` profile: it hunts for what the fixed scenario families didn't
think to test, delegating attack mechanics to the sibling `fisco-bcos-testing` and
`fisco-bcos-vuln-hunt` skills.

> Status: the bundled shell scripts are syntax-checked and their pure functions are unit-tested
> (`bash -n` + `tests/*_test.sh`, see below); the live-chain paths have not been run end-to-end in
> every environment. Treat paths/ports as defaults and adapt to your setup.

---

## What it gives you

- **Production-faithful local reproduction** — `apply_profile.sh` replays a captured `.profile`
  onto a local AIR cluster: genesis `compatibility_version` via `build_chain -v`, `config.ini`
  overrides, and live `setSystemConfigByKey` replay for flags that were turned on post-genesis
  (not creation-time constants).
- **Three pure-function failure oracles** — crash (dead PID / core dump), consensus-halt (block
  height flat past `RG_STALL_SEC` while transactions are pending), state-mismatch (`stateRoot`
  divergence across nodes) — each judged by an IO-free decision function, unit-tested directly.
  No log-grep-for-`ERROR` oracle by design (noisy, false-positive-prone).
- **Four gate scenario families** — `ut` (every module's UT binary via the sibling
  `fisco-bcos-testing` skill), `dual_rpc` (BCOS RPC vs Web3 RPC stateRoot comparison), `malformed`
  (byte-tampered tx, asserts clean rejection not a crash-masquerading-as-one), `jsd`
  (java-sdk-demo's three DMC transfer shapes under real parallel load, DAG on and off, each checked
  against its own balance-conservation assertion).
- **A separate `upgrade` entry point** — the production profile's T0-T8 version-upgrade timeline
  (`scenario_upgrade.sh`). Not one of the four gate scenario families: it needs old/new binaries
  and a target version `gate.sh`'s bare-dispatch loop can't supply, so selecting it via
  `--scenarios upgrade` is a hard rejection (exit 2) rather than something the sweep runs; drive it
  directly instead (see `references/upgrade-path.md`).
- **6 hand-curated profiles** — one real captured production snapshot
  (`production-enterprise`) plus 5 archetypes covering SM-crypto, rPBFT scale, fresh install,
  EVM-full, and a long-distance-upgrade starting point.
- **A flywheel** — a confirmed exploration-layer finding gets distilled into a `.case` regression
  fixture under `scenarios/`, replayed by `run_case.sh`, so a fixed defect can't silently
  resurface unnoticed.
- **Local-first defect logging** — every oracle trip is appended to a local `failures.jsonl`
  (zero network); syncing those rows to the Tencent smartsheet defect ledger is a separate,
  explicit step (`report_defects.sh`).

---

## Requirements

- **Claude Code** — the skill runs inside it.
- **A FISCO-BCOS source checkout**, with this skill nested at
  `.claude/skills/fisco-bcos-release-gate/` — scripts locate the repo root by walking up looking
  for `tools/BcosAirBuilder/build_chain.sh`.
- **The sibling `fisco-bcos-testing` skill checked out alongside this one** — `apply_profile.sh`'s
  real-run path and the `ut` scenario both call into its `scripts/cluster_up.sh` /
  `scripts/run_ut.sh`.
- **bash 4+** — every script checks `BASH_VERSINFO[0]` up front and fails with an explicit
  message on stock macOS bash 3.2 (`declare -gA` needs 4+). `brew install bash` first on macOS.
- **For live gate runs**: a compiled `fisco-bcos` binary, plus whatever the delegated
  `fisco-bcos-testing` scenarios need (Node.js for Web3 RPC, JDK 11+ for the console).

---

## Install

A Claude Code skill is a folder that Claude Code auto-discovers. Put this folder in one of:

- **Per-project** (recommended) — `<your-FISCO-BCOS-checkout>/.claude/skills/fisco-bcos-release-gate/`.
  It then triggers only when you work in that repo.
- **Global** (all projects) — `~/.claude/skills/fisco-bcos-release-gate/`.

```bash
git clone <this-repo-url> fisco-bcos-release-gate

# project-scoped:
mkdir -p /path/to/FISCO-BCOS/.claude/skills
cp -r fisco-bcos-release-gate /path/to/FISCO-BCOS/.claude/skills/

# or global:
mkdir -p ~/.claude/skills
cp -r fisco-bcos-release-gate ~/.claude/skills/
```

Open (or restart) Claude Code in the target repo. The skill appears in the available-skills list
automatically; no registration step.

---

## Use

Describe a release-gate task in natural language while working in a FISCO-BCOS checkout — Claude
invokes the skill when the task matches. Examples:

- `跑一轮发布门禁` · `run a release gate`
- `regression-test this build before shipping`
- `reproduce the production profile locally and check it's clean`
- `test the 3.16.4 → 3.17.0 upgrade path`
- `持续循环测试,找没想到的问题`

You can also be explicit: *"use the fisco-bcos-release-gate skill to …"*.

When it triggers, Claude announces it and follows `SKILL.md`: Step 0 决定走哪条腿 → 加载 profile →
apply_profile 回放 → gate 四场景族 → 三 oracle → (production-enterprise only, after a clean pass)
探索层 → 飞轮沉淀 → 报告.

---

## What's inside

```
fisco-bcos-release-gate/
├── SKILL.md                              the workflow Claude follows (entry point)
├── README.md                             this file
├── CLAUDE.md                             guidance for Claude Code editing this repo's own source
├── scripts/
│   ├── apply_profile.sh                  replay a captured .profile onto a local AIR cluster
│   ├── gate.sh                           orchestrator: bring up cluster, run scenarios, judge oracles
│   ├── profile_lib.sh                    .profile parser (profile_load -> PROFILE_* arrays)
│   ├── oracle_lib.sh                     pure decision functions (liveness/fork/stateroot)
│   ├── oracle_crash.sh                   crash oracle: dead PID / core dump + RPC hang probe
│   ├── oracle_liveness.sh                consensus-halt oracle: block-height stall detection
│   ├── oracle_stateroot.sh               state-mismatch oracle: stateRoot comparison across nodes
│   ├── run_case.sh                       replay one scenarios/*.case regression fixture
│   ├── failures_lib.sh                   local failures.jsonl sink (failures_append)
│   ├── report_defects.sh                 sync unreported failures.jsonl rows to the Tencent smartsheet
│   └── scenarios/                        the 4 general-purpose gate scenario families, + upgrade
│       ├── scenario_ut.sh                runs every module's UT binary (crash oracle)
│       ├── scenario_dual_rpc.sh          BCOS RPC vs Web3 RPC deploy+call, stateRoot comparison
│       ├── scenario_malformed.sh         byte-tampered tx, asserts clean rejection
│       ├── scenario_jsd.sh               java-sdk-demo DMC load, balance conservation (needs JSD_DIR)
│       └── scenario_upgrade.sh           T0-T8 upgrade timeline; separate entry point, not a GATE_KNOWN_SCENARIOS member
├── profiles/                             6 hand-maintained captured/archetype .profile files
│   ├── production-enterprise.profile     the one real captured snapshot — the anchor
│   ├── sm-gov.profile
│   ├── rpbft-scale.profile
│   ├── default-latest.profile
│   ├── evm-full.profile
│   └── upgrade-legacy.profile
├── scenarios/                            regression .case fixtures (the flywheel) — NOT scripts/scenarios/
│   ├── README.md                         the .case format + the flywheel flow
│   └── example.case
├── references/                           loaded by Claude on demand
│   ├── oracle-detection.md               the three oracles' decision logic, thresholds, tuning
│   ├── profile-authoring.md              how to hand-capture a new production .profile
│   └── upgrade-path.md                   T0-T8 operational detail + how scenario_upgrade_run gets its args
└── tests/                                bash unit tests (tests/assert.sh + tests/*_test.sh)
```

---

## Design principles

- **Two directories, both named "scenarios," different jobs.** `scripts/scenarios/` holds 4 broad
  `scenario_*.sh` families run every gate round, plus `scenario_upgrade.sh` — a separate,
  directly-invoked entry point, not swept by `gate.sh`; top-level `scenarios/` holds narrow,
  one-fixture-per-confirmed-failure `.case` files. See `scenarios/README.md`.
- **Facts don't get baked in.** Methodology is fixed; per-release facts (feature-flag names, exact
  line numbers, current version strings) are re-derived at run time — grep `Features.cpp`, run
  `listSystemConfigs`, read the current `config.genesis` — never hardcoded into a script or doc.
- **Stated accurately, not aspirationally.** Known gaps (`gate.sh` doesn't auto-replay
  `scenarios/*.case`; `cluster_up.sh` has no `compatibility_version` passthrough yet) are
  documented as current state in `SKILL.md`, not silently worked around or claimed fixed. `upgrade`
  itself is not a gap: it needs old/new binaries + a target version the bare-dispatch loop can't
  supply, so `gate.sh` rejects `--scenarios upgrade` outright (exit 2) rather than silently
  skipping it, and it's driven directly instead (see `references/upgrade-path.md`).

---

## Scope & limits

- **AIR mode only.** Pro/Max deployment is out of scope.
- **RocksDB storage only** (`key_page_size=0`). TiKV storage is not tested.
- **DAG execution is tested; sharding is not.**
- **No log-grep-for-`ERROR` oracle**, by design — see `references/oracle-detection.md`.

---

## License

This skill ships without a license — add one before publishing. FISCO-BCOS itself is Apache-2.0; a
matching `Apache-2.0` is a reasonable default.
