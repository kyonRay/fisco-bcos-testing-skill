# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Claude Code skill** (`fisco-bcos-testing`) — prose workflow docs plus two shell scripts. There is
no build system, no test suite, no lint config. The "product" is the text Claude follows at run time
when a user asks to test FISCO-BCOS (AIR mode, 3.x).

This repo is normally checked out **nested inside a FISCO-BCOS source tree** at
`.claude/skills/fisco-bcos-testing/` (it is its own git repo; the surrounding checkout is a different
one). Both scripts assume that placement: they locate the FISCO-BCOS repo root by walking up from
`$PWD` until they find `tools/BcosAirBuilder/build_chain.sh` (`find_repo_root()` in both scripts).

## Commands

```bash
# Syntax-check the scripts (the only automated verification this repo has)
bash -n scripts/cluster_up.sh scripts/run_ut.sh

# Exercise the scripts for real (requires a FISCO-BCOS checkout + binary; run from inside one)
scripts/cluster_up.sh -n 4 -o ./nodes-test        # build_chain → enable Web3 RPC → start → poll :8545
scripts/run_ut.sh txpool --run_test=SomeSuite      # find & run build/bcos-txpool/test/test-bcos-txpool
./nodes-test/127.0.0.1/stop_all.sh                 # tear down a test cluster
```

To test the skill end to end, open Claude Code in a FISCO-BCOS checkout containing this folder and
issue a matching request (e.g. "测一下 FIB-33 的修复"); the skill should trigger and follow SKILL.md.

## Architecture: progressive disclosure

Three layers, each loaded later and costing more tokens than the last:

1. **`SKILL.md` frontmatter `description`** — the trigger surface. Claude scans only this to decide
   whether to invoke the skill. It enumerates tasks and Chinese/English trigger phrases ("提测",
   "黑盒测试", "eth_sendRawTransaction 测试", …). Any scope change (new capability, new tool) must be
   reflected here or it will never fire for that use case.
2. **`SKILL.md` body** — the workflow loaded on invocation: Step 0 frame → Step 1 cluster → Step 2
   classify by the 三桶 reachability model → Step 3 pick the RPC/tool → Step 4 execute → Step 5
   false-green guards → Step 6 evidence matrix, plus operational dimensions (upgrade, governance,
   stress). It routes to references via tables; it should stay an index + decision logic, not absorb
   reference-level detail.
3. **`references/*.md`** — loaded on demand, one per workflow branch (~50–110 lines each). Each maps
   to a bucket or operational dimension; the mapping lives in SKILL.md's "Bundled resources" table.

`scripts/` are the only executables. `cluster_up.sh` wraps `build_chain.sh` → flips
`[web3_rpc] enable=true` in each node's `config.ini` (mirroring CI) → `start_all.sh` → polls
`eth_blockNumber` on :8545. `run_ut.sh` is the Bucket C fallback runner for module Boost.Test
binaries (`build/bcos-<module>/test/test-bcos-<module>`).

## Core concepts the docs are built around

Editing any file requires keeping these consistent — they cross-reference each other:

- **三桶 (three-bucket) reachability model** — Bucket A (stock SDK/curl), B (byte-tampering at RPC),
  C (P2P/consensus, unreachable black-box → UT-only evidence via `run_ut.sh`).
- **Two distinct RPC services** — BCOS RPC (port 20200, tars-encoded, console/Java SDK) vs Web3 RPC
  (port 8545, Ethereum RLP, Viem/ethers/Hardhat). Never conflate them; most fixes are reachable via
  only one.
- **False-green guards** — every negative case pairs a positive control + a node-alive probe.
- **Evidence honesty** — the matrix distinguishes `live black-box` from `UT-only`; never upgrade one
  to the other.

## Editing invariants

- **Methodology in, per-release facts out.** The skill encodes stable procedures only. Do NOT bake in
  FIB lists, PR numbers as authoritative data, exact source line numbers, or current feature-flag
  names — write the grep/console command that re-derives them instead (see SKILL.md "Design rule").
  The only baked-in facts allowed are wire-protocol stable: tars `Transaction` field numbers
  (2 dataHash, 4 importTime, 7 sender, 9 type, 11 extraTransactionHash) and default ports
  30300/20200/8545.
- **Cross-file sync on add/rename.** A new reference or script must be added to (a) SKILL.md's
  "Bundled resources" table, (b) the tool/step table that routes to it, and (c) README's
  "What's inside" tree.
- **Scope guard.** AIR mode only; MAX/Tars is explicitly out of scope. Widening scope means updating
  the frontmatter description, SKILL.md's scope line, and README "Scope & limits" together.
- **Bilingual terms are intentional.** Chinese domain terms (提测, 三桶, 国密/SM, 灰度升级, 常稳,
  正向回归) appear alongside English because users trigger and read in both; keep them paired, don't
  "translate away" either side.
- **Scripts**: bash with `set -euo pipefail`, `getopts`, `-h` prints the header comment block via
  `grep '^#'`, errors give the user actionable options rather than guessing (e.g. cluster_up's
  three-way binary prompt). Keep new scripts in that shape.
