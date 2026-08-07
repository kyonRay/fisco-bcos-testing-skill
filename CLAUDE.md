# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Claude Code skill** (`fisco-bcos-release-gate`) — a release-gate test harness for FISCO-BCOS
(AIR mode). It reproduces a production chain's exact config profile locally, runs five gate
scenario families against it, and judges each run under three failure oracles (crash /
consensus-halt / state-mismatch), recording any defect found.

This repo is normally checked out **nested inside a FISCO-BCOS source tree** at
`.claude/skills/fisco-bcos-release-gate/` (it is its own git repo; the surrounding checkout is a
different one), as a sibling of `fisco-bcos-testing` and `fisco-bcos-vuln-hunt` — this skill's
`gate.sh`/`apply_profile.sh` real-run paths and the `ut` scenario call directly into
`fisco-bcos-testing`'s `scripts/cluster_up.sh` / `scripts/run_ut.sh`, so that sibling must be
checked out alongside this one for anything beyond `--dry-run`/`SCENARIO_DRY=1`.

`scripts/`, `profiles/`, `scenarios/`, and `references/` all hold real content now (this section
no longer describes an empty scaffold) — see "Architecture: progressive disclosure" below for what
each holds.

## Commands

```bash
# Syntax-check every script (the fast, no-chain-needed check)
bash -n scripts/*.sh scripts/scenarios/*.sh tests/*.sh

# Run one test file
bash tests/<x>_test.sh

# Run every test file
for t in tests/*_test.sh; do echo "== $t =="; bash "$t"; done

# Self-test the assertion helper itself
bash -c 'source tests/assert.sh; assert_eq a a t1; assert_done'

# Dry-run the two orchestration scripts (no chain touched, safe anywhere)
bash scripts/apply_profile.sh -p profiles/production-enterprise.profile --dry-run
bash scripts/gate.sh -p profiles/production-enterprise.profile --dry-run

# Every script's own usage/header doc
bash scripts/<script>.sh -h
```

**Requires bash 4+.** Every script under `scripts/` checks `BASH_VERSINFO[0]` up front (associative
arrays: `PROFILE_*` in `profile_lib.sh`, `GATE_SCENARIOS` in `gate.sh`) and fails with an explicit
message instead of a cryptic `declare -gA` parse error on stock macOS bash 3.2 — `brew install
bash` first on macOS and make sure it's ahead of `/bin/bash` on `PATH` before running any of the
above.

To test the skill end to end, open Claude Code in a FISCO-BCOS checkout containing this folder and
issue a matching request (e.g. "跑一轮发布门禁"); the skill should trigger and follow SKILL.md.

## Architecture: progressive disclosure

Three layers, each loaded later and costing more tokens than the last:

1. **`SKILL.md` frontmatter `description`** — the trigger surface. Claude scans only this to
   decide whether to invoke the skill. It enumerates tasks and Chinese/English trigger phrases
   ("发布门禁", "release gate", "profile 回放", …). Any scope change (new scenario family, new
   oracle) must be reflected here or it will never fire for that use case.
2. **`SKILL.md` body** — the workflow loaded on invocation: Step 0 框定 → 加载 profile →
   apply_profile 回放 → gate 四场景族 → 三 oracle → 探索层 → 飞轮沉淀 → 报告, plus a "Bundled
   resources" table at the end mapping every script/profile/reference to the workflow branch that
   reads it. It routes to `profiles/`, `scenarios/`, and `references/` via tables; it should stay
   an index + decision logic, not absorb reference-level detail.
3. **`profiles/`, `scenarios/`, `references/*.md`** — loaded on demand.
   - `profiles/` — 6 hand-maintained `.profile` files (one real captured production snapshot,
     5 archetypes), parsed by `scripts/profile_lib.sh`.
   - `scenarios/` — regression `.case` fixtures (the flywheel), replayed by `scripts/run_case.sh`.
     **Not the same directory as `scripts/scenarios/`** — see the note below.
   - `references/*.md` — detail docs for oracles, profile capture, and the upgrade path, one per
     workflow branch (~50-110 lines each, index/routing altitude — SKILL.md points here rather
     than absorbing this detail itself).

`scripts/` holds every executable. **Two directories are both named "scenarios" — do not conflate
them**:
- `scripts/scenarios/scenario_<name>.sh` — the 5 general-purpose gate scenario families
  (`ut`/`dual_rpc`/`malformed`/`jsd`/`upgrade`), self-registering into `gate.sh`'s `GATE_SCENARIOS` map
  when sourced.
- `scenarios/*.case` (top-level) — narrow, one-fixture-per-confirmed-failure regression files (see
  `scenarios/README.md`). `gate.sh` does not currently sweep this directory automatically.

`tests/assert.sh` is the shared assertion helper all shell unit tests in this repo source
(`assert_eq`, `assert_contains`, `assert_done`); `tests/*_test.sh` covers every pure function
(`oracle_*_decide`, `profile_load`, `_upg_no_fork`/`_upg_flag_flipped`, etc.) hermetically, with no
live chain required — the live-chain IO paths in each script are exercised only manually.

## Editing invariants

- **Scope guard (four constraints, bake into every scenario/profile/script).**
  - 部署形态仅 Air — do not add Pro/Max scenarios or profiles.
  - 存储仅 RocksDB + `key_page_size=0` — do not add TiKV storage profiles.
  - 执行测 DAG、不测 sharding — scenario families stay within DAG execution; no sharding scenarios.
  - 不做日志 ERROR 关键字判决 — the three oracles are crash / consensus-halt / state-mismatch only;
    do not add a log-grep-for-ERROR oracle.
  Widening any of these means updating this list, the frontmatter description, and SKILL.md's
  scope section together.
- **Cross-file sync on add/rename.** A new scenario family, oracle, profile, or reference must be
  reflected in (a) SKILL.md's relevant skeleton section, (b) SKILL.md's "Bundled resources" table,
  (c) README.md's "What's inside" tree, and (d) this file's directory descriptions above.
- **Facts don't get baked in.** Methodology goes in the skill; per-release facts (specific FIB
  numbers, exact config values from one incident, current version strings, the current bugfix-flag
  list) do not — write the command that re-derives them instead (e.g. grep
  `Features.cpp`'s `upgradeRoadmap` table, run `listSystemConfigs`, read `config.genesis`).
- **Scripts**: bash with `set -euo pipefail`, fail-fast, `getopts` for flag parsing, `-h` prints
  the script's own header comment block via `grep '^#' "$0" | sed 's/^# \{0,1\}//'` (every script
  under `scripts/` follows this convention — match it in any new one). Reuse `tests/assert.sh`
  (`assert_eq`, `assert_contains`, `assert_done`) for pure-function unit tests rather than adding a
  second assertion helper. A `scripts/scenarios/scenario_*.sh` family file is sourced by `gate.sh`
  (not executed on its own) and must not `set -e`/`set -u` at file scope — that would change the
  sourcing script's own shell options; guard any `declare -gA` registration the same way
  `scenario_upgrade.sh` and its siblings do. This does not extend to every sourced file: library
  files that are always sourced into an already-`set -euo pipefail` caller, like `profile_lib.sh`
  and `oracle_lib.sh`, keep `set -euo pipefail` at their own file scope too — check a given file's
  actual header before assuming either convention.
