# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Claude Code skill** (`fisco-bcos-release-gate`) — a release-gate test harness for FISCO-BCOS
(AIR mode). It reproduces a production chain's exact config profile locally, runs four gate
scenario families against it, and judges each run under three failure oracles (crash /
consensus-halt / state-mismatch), recording any defect found.

This repo is normally checked out **nested inside a FISCO-BCOS source tree** at
`.claude/skills/fisco-bcos-release-gate/` (it is its own git repo; the surrounding checkout is a
different one), as a sibling of `fisco-bcos-testing` and `fisco-bcos-vuln-hunt`.

As of this scaffold, `scripts/`, `profiles/`, `scenarios/`, and `references/` are empty
placeholders (`.gitkeep` only) — no logic has been implemented yet. This section will need
updating once those directories gain real content.

## Commands

```bash
# Syntax-check any shell scripts added under scripts/
bash -n scripts/*.sh

# Run a specific assertion-based test file
bash tests/<x>_test.sh

# Self-test the assertion helper itself
bash -c 'source tests/assert.sh; assert_eq a a t1; assert_done'
```

To test the skill end to end, open Claude Code in a FISCO-BCOS checkout containing this folder and
issue a matching request (e.g. "跑一轮发布门禁"); the skill should trigger and follow SKILL.md.

## Architecture: progressive disclosure

Three layers, each loaded later and costing more tokens than the last:

1. **`SKILL.md` frontmatter `description`** — the trigger surface. Claude scans only this to
   decide whether to invoke the skill. It enumerates tasks and Chinese/English trigger phrases
   ("发布门禁", "release gate", "profile 回放", …). Any scope change (new scenario family, new
   oracle) must be reflected here or it will never fire for that use case.
2. **`SKILL.md` body** — the workflow loaded on invocation: Step 0 框定 → 加载 profile →
   apply_profile 回放 → gate 四场景族 → 三 oracle → 探索层 → 飞轮沉淀 → 报告. It routes to
   `profiles/`, `scenarios/`, and `references/` via tables; it should stay an index + decision
   logic, not absorb reference-level detail.
3. **`profiles/`, `scenarios/`, `references/*.md`** — loaded on demand. `profiles/` holds captured
   production config profiles; `scenarios/` holds the four gate scenario families; `references/`
   holds detail docs for oracles and other workflow branches, one per branch.

`scripts/` will hold the only executables (profile capture/apply, scenario runners, oracle
checks) once implemented; `tests/assert.sh` is the shared assertion helper all future shell unit
tests in this repo source.

## Editing invariants

- **Scope guard (four constraints, bake into every scenario/profile/script).**
  - 部署形态仅 Air — do not add Pro/Max scenarios or profiles.
  - 存储仅 RocksDB + `key_page_size=0` — do not add TiKV storage profiles.
  - 执行测 DAG、不测 sharding — scenario families stay within DAG execution; no sharding scenarios.
  - 不做日志 ERROR 关键字判决 — the three oracles are crash / consensus-halt / state-mismatch only;
    do not add a log-grep-for-ERROR oracle.
  Widening any of these means updating this list, the frontmatter description, and SKILL.md's
  scope section together.
- **Cross-file sync on add/rename.** A new scenario family, oracle, or profile must be reflected
  in (a) SKILL.md's relevant skeleton section, (b) any routing table that points to it, and
  (c) this file's directory descriptions above.
- **Facts don't get baked in.** Methodology goes in the skill; per-release facts (specific FIB
  numbers, exact config values from one incident, current version strings) do not — write the
  command that re-derives them instead.
- **Scripts**: bash with `set -euo pipefail`, fail-fast. Reuse `tests/assert.sh`
  (`assert_eq`, `assert_contains`, `assert_done`) for pure-function unit tests rather than adding a
  second assertion helper.
