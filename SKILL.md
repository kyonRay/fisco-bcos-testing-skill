---
name: fisco-bcos-testing
description: >-
  Test the FISCO-BCOS blockchain (AIR single-process mode) end to end — spin up a local
  4-node cluster, drive it with the official tooling (the Java console, java-sdk-demo stress
  tests, build_chain auth mode, the newman/Hardhat CI suites) plus modern Ethereum tools (Viem,
  ethers.js) and curl, send transactions from natural-language intent, exercise BOTH distinct RPC
  services — BCOS RPC (console, tars-encoded sendTransaction) and Web3 RPC (Viem/ethers/Hardhat,
  Ethereum-spec eth_* with RLP) — classify each test
  point by black-box reachability (三桶 model), tamper transaction bytes to test validation, run
  module unit-test binaries as evidence, test version-upgrade compatibility (rolling binary swap,
  compatibility_version bump, feature-flag/hardfork gating, mixed-version no-fork, rollback), test
  permission governance (deploy/method authorization), run stress / long-stability / performance
  regression, and emit an evidence matrix. Use this skill WHENEVER the user wants to test
  FISCO-BCOS, run black-box / integration / regression tests against a node, validate
  security-audit fixes (CertiK / FIB findings), execute or operationalize a 提测 (QA handover) doc,
  send or forge transactions via sendTransaction or eth_sendRawTransaction, check that malformed /
  malicious input is rejected, reproduce a P2P / consensus attack, test a version upgrade or its
  backward compatibility, toggle a feature flag / bugfix / hardfork, exercise permission governance,
  stress-test or measure performance, or stand up a local AIR cluster — even if they don't say the
  word "skill" or "test harness". Triggers on: "测试 FISCO-BCOS", "提测", "黑盒测试",
  "FIB / 审计 验证", "起一条链测", "eth_sendRawTransaction 测试", "构造畸形交易", "跑 UT 当证据",
  "版本升级 / 升级兼容", "灰度升级", "feature flag / hardfork", "权限治理", "压力测试 / 压测", "控制台",
  "用 Viem / ethers 发交易", "BCOS RPC vs Web3 RPC", "自然语言发交易测试".
---

# FISCO-BCOS Testing (AIR mode)

This skill turns a vague "test FISCO-BCOS" or "verify these audit fixes" request into a concrete,
reproducible run against a real node. Its job is to keep you from two classic failure modes:

1. **Testing the unreachable.** Many security fixes live behind the P2P / consensus frame layer,
   which JSON-RPC cannot touch. Trying to "black-box" them via the SDK wastes hours and produces
   false confidence. The reachability model below tells you up front what is testable and how.
2. **False greens.** A transaction that gets "rejected" because the node *crashed* parsing it looks
   identical to a clean rejection unless you check. The guards below make every negative result earn
   its pass.

Scope: **AIR mode only** (`fisco-bcos-air`, single process). MAX/Tars microservice mode is out of
scope for this version.

---

## When you don't know — don't guess, escalate to the source

Testing constantly surfaces unknowns: a command's exact syntax, a config key, a return code, whether
some behavior is by-design. **Never guess or invent an answer** — a fabricated expected-result turns a
test into noise and a false pass into a shipped bug. Resolve it against authoritative sources, in this
order, before asserting anything:

1. **Local doc checkout** (fastest, if present) — grep the FISCO-BCOS docs on disk, e.g.
   `~/workspace/code/FISCO-BCOS-DOC/3.x/zh_CN/docs/`.
2. **Online docs** — https://fisco-bcos-doc.readthedocs.io/zh-cn/latest
3. **Docs repo** — https://github.com/FISCO-BCOS/FISCO-BCOS-DOC/tree/release-3/3.x/zh_CN
4. **Node source** (when the docs don't cover it) — the local checkout you're in, or
   https://github.com/FISCO-BCOS/FISCO-BCOS . Read the actual implementation; that's ground truth.
5. **Console source** (for console-command behavior specifically) —
   https://github.com/FISCO-BCOS/console

If it's still unresolved after this, write "unknown — needs investigation" in the evidence-matrix
Notes; do not assert an expected result you couldn't anchor to a doc or to code.

---

## Step 0 — Frame the request

Decide which of these you're doing, because it changes everything downstream:

- **One behavior / one fix** → go straight to the reachability model, classify it, execute.
- **A whole audit / 提测 handover doc** (e.g. `audit/CertiK_release-3.17.0_提测文档.md`) → read
  `references/audit-qa-playbook.md`. That playbook tells you how to walk the doc case-by-case,
  reuse its bucket tags, and produce the evidence matrix it asks for.

Then make sure a cluster is running (Step 1).

---

## Step 1 — Bring up a cluster

If no node is running (`pgrep -fl fisco-bcos` is empty), use the bundled script. It wraps
`build_chain.sh` → `start_all.sh` → waits until RPC actually answers:

```bash
.claude/skills/fisco-bcos-testing/scripts/cluster_up.sh -n 4 -o ./nodes-test
# 国密 (SM) variant:
.claude/skills/fisco-bcos-testing/scripts/cluster_up.sh -n 4 -o ./nodes-test-sm -s
```

It defaults to the binary at `build/fisco-bcos-air/fisco-bcos`.

**No binary there? Don't guess or silently pick one — ask the user (AskUserQuestion)** which of these
to do, then act on the choice:

1. **Specify an existing binary** — they give a path; run `cluster_up.sh -e <path>`.
2. **Download a release binary** (quick-start) — run `cluster_up.sh -d`, which calls `build_chain.sh`
   *without* `-e` so it fetches an official release binary. Method:
   <https://fisco-bcos-doc.readthedocs.io/zh-cn/latest/docs/quick_start/air_installation.html>
3. **Compile from source** — clone <https://github.com/FISCO-BCOS/FISCO-BCOS> (or build the local
   checkout you're in per `CLAUDE.local.md`), then `cluster_up.sh -e build/fisco-bcos-air/fisco-bcos`.

**This caveat decides the choice:** a downloaded *release* binary does **not** contain unreleased /
unmerged fixes. To test an audit fix that isn't in a release yet, you **must** use option 1 (a branch
build) or option 3 (compile the branch under test) — option 2 only serves general / regression /
Ethereum-compat testing where released behavior is what you want.

Ports (per node, offset by node
index): P2P from **30300**, BCOS RPC from **20200**, Web3 RPC from **8545** (the generated config
defaults `[web3_rpc] enable=false`; `cluster_up.sh` flips it on, as CI does). For
crypto-touching fixes, bring up **both** an SM and a non-SM group — a fix can pass on one suite and
fail on the other. For **permission-governance** fixes the default cluster won't do — stand up an
auth-enabled chain (`build_chain.sh -A` / `-a <addr>`); see `references/permission-governance.md`.

Tear down with `./nodes-test/127.0.0.1/stop_all.sh`.

---

## Step 2 — The reachability model (三桶) — classify before you test

Every test point falls into one of three buckets. **Classify first**; the bucket dictates the tool
and whether a black-box tester can even do it. Ask two questions:

- **Where does the malicious/test input enter?** An RPC parameter → Bucket A or B. A P2P frame, a
  block-sync message, or a consensus message → Bucket C.
- **Does a stock SDK produce this exact input?** Yes (a legal, correctly-signed tx) → Bucket A.
  No — you need malformed or content/hash-decoupled bytes the SDK refuses to make → Bucket B.

| Bucket | Reachable with | What it covers | Where to go |
|--------|----------------|----------------|-------------|
| **A** | stock SDK / curl (ethers.js, Java/cpp SDK) | legal input + node's observable reject/charge/dedup behavior: tx on-chain, nonce replay, pool-full rejection, gas charged, auth denied | `references/rpc-paths.md` |
| **B** | byte-tampering at RPC | input *reaches* RPC but the SDK won't forge it — content/hash mismatch, unknown tx type, prefilled sender, malformed `to`, negative importTime | `references/byte-tampering.md` |
| **C** | P2P / consensus injection | attack surface is the frame/sync/consensus layer; JSON-RPC cannot reach it at all | `references/p2p-injection.md` |

**Bucket C has a mandatory fallback.** If no malicious-node patch or raw-socket injector is
available, do **not** mark the case untested — run the module's UT binary that exercises the same
decode/verify path and record it as **UT-only evidence** (see Step 5 and `scripts/run_ut.sh`). The
fix's authors already wrote that test; running it is real evidence, just not black-box.

---

## Step 3 — Two RPCs, and the tools for each (the entry map)

FISCO-BCOS exposes **two different RPC services with different interface specs.** They are not
interchangeable, and **most fixes are reachable through only one of them — decide which before you
test.**

| | **BCOS RPC** | **Web3 RPC** |
|--|--------------|--------------|
| Spec | FISCO-BCOS's own interface | Ethereum JSON-RPC spec |
| Methods | `sendTransaction`, `call`, `getTransactionReceipt`, `getSystemConfigByKey`, … | `eth_sendRawTransaction`, `eth_call`, `eth_getTransactionReceipt`, `eth_chainId`, … |
| Wire | tars-encoded `bcostars::Transaction` hex | Ethereum RLP hex |
| Port | **20200** | **8545** (chainId = config `web3_chain_id`, query it) |
| Clients | **Java console**, Java/cpp SDK | **Viem**, ethers.js, web3.js, Hardhat |
| Fixes that live here | native tx validation, tars-field tampering (FIB-33 `dataHash`), system-config/upgrade | Ethereum-compat behavior, RLP decode, canonical txHash (New-1) |

**Cross-path footgun:** both RPCs share one ledger, and the Web3 path must be turned on **from the
BCOS RPC console** before it works: enable the balance model + Web3 chain id (system configs
`feature_balance`/`balance_transfer`/`web3_chain_id`/`tx_gas_price`, check with `listSystemConfigs`),
then `addBalance` the account. And `web3_chain_id` is a config — **query it** (`getSystemConfigByKey
web3_chain_id`), don't hardcode 20200, or Viem/ethers reject every tx on a chainId mismatch. Full
sequence in `rpc-paths.md` / `ci-harnesses.md`.

**Send transactions by natural-language intent** — don't hand-assemble. Describe the tx ("send 0.1
ether to 0xBob", "deploy HelloWorld and call set('hi')") and let the tool build it: **Viem** (or
ethers.js) for the Web3 RPC, the **console** for the BCOS RPC. This is the fast path for both a human
and an AI driver. Recipes in `references/rpc-paths.md`.

**Tool selection:**

| Tool | RPC / use | Reference |
|------|-----------|-----------|
| **Java console** | BCOS RPC client + node observation (`getSyncStatus`/`getConsensusStatus`/`getPendingTxSize`/`get`,`setSystemConfigByKey`) | `references/console.md` |
| **Viem / ethers.js** | Web3 RPC — build & send Web3 txs from NL intent | `references/rpc-paths.md` |
| **ready CI suites** (newman BCOS-RPC-API, Hardhat `bcos-testing`, `ci_check_air.sh`) | positive/compat regression for each RPC — run these first | `references/ci-harnesses.md` |
| **java-sdk-demo** | high-QPS load: resource cases, long-stability, perf | `references/stress-and-stability.md` |
| **build_chain.sh `-A`/`-a`** | stand up a permission-governance chain | `references/permission-governance.md` |
| **curl** | inject raw/tampered tars hex into BCOS `sendTransaction` (Bucket B) | `references/byte-tampering.md` |

---

## Step 4 — Execute, per bucket

- **Bucket A** → `references/rpc-paths.md`. Send legal input, assert on the receipt
  (`status`, `gasUsed`, `output`) or on RPC behavior (nonce replay rejected, pool-full rejected).
- **Bucket B** → `references/byte-tampering.md`. Build a valid tx, flip exactly one field in the
  tars/RLP struct, re-encode, inject via `curl`, assert it is rejected. The field map (tars field
  numbers) is there and is stable wire-protocol — safe to rely on.
- **Bucket C** → `references/p2p-injection.md`. Either drive an injector, or run the UT binary as
  evidence via `scripts/run_ut.sh`.

---

## Step 5 — False-green guards (do not skip)

A negative case proves nothing on its own. **Every negative/rejection case must pair:**

1. **A positive control** — the *same path* with legal input succeeds. This proves you tested the
   thing, not a broken connection or a wrong port. (The audit/提测 doc already pairs each negative
   group with a "正向回归" requirement — reuse it.)
2. **A node-alive probe afterward** — `eth_blockNumber` (Web3 RPC) or `getBlockNumber` (BCOS RPC) still
   advances. This distinguishes "node cleanly rejected the input" from "node crashed/aborted parsing
   it", which on the wire can look the same.

If either is missing, the result is not a pass — it is *unknown*.

---

## Step 6 — Output: the evidence matrix

Report results as a matrix so "tested" vs "merely cited a UT" is never conflated:

```
| Case | FIB / PR | Bucket | Evidence | Result | Notes |
|------|----------|--------|----------|--------|-------|
| SIG-01 | FIB-33 / #5077 | B | live black-box | PASS | forged dataHash rejected; node alive; positive control on-chain |
| SIG-04 | New-1 / #5210 | C | UT-only (N1_T2) | PASS | RPC entry overwrites the field — P2P-only; ran test-bcos-tars-protocol |
| IN-01  | FIB-66 / #5110 | C | UT-only | PASS | no injector available; ran test-bcos-gateway decode case |
```

**Evidence** column is the honesty knob: `live black-box` means you actually exercised the running
node; `UT-only` means you ran the unit test that covers the same path but could not reach it
black-box. Never label UT-only as black-box verified.

---

## Operational test dimensions (orthogonal to the buckets)

The 三桶 model is about *input reachability* for a single fix. A release also has to survive being
**operated** — upgraded, governed, loaded. These dimensions cut across the whole release and are
where the highest-impact regressions hide. Cover them in addition to the per-fix buckets.

### Version-upgrade compatibility — the top one, test it thoroughly

A node can be perfect in isolation and still fork the chain on a rolling upgrade, or silently fail to
activate a fix because the data version wasn't bumped. Read `references/version-upgrade.md`. The core
checks: **mixed old/new binary window stays fork-free**; binary-only upgrade does *not* enable
version-gated fixes (`getSystemConfigByKey compatibility_version`); each **feature flag / bugfix /
hardfork** toggled via `setSystemConfigByKey` behaves per its FIB in both states; rollback works for
reversible changes; pre-upgrade data stays readable.

This is where an audit **hardfork** bites: FIB-134 (packetType bound into the PBFT signature) and the
feature-gated fixes (e.g. nonce-rollback, delegatecall-transfer, precompiled gating) are gated by
exactly this `compatibility_version` / `setSystemConfigByKey` machinery — so they must be tested
*through the upgrade procedure*, on both an un-bumped chain (off) and a bumped chain (on), and a
hardfork must be enabled group-wide consistently or the group stalls.

### Permission governance

Several fixes (deploy authorization, auth-failure handling, system-tx authorization) only manifest on
a governance-enabled chain. Read `references/permission-governance.md`. Pattern: unauthorized op →
denied (return code **18**) + authorized op succeeds (positive control) + node alive.

### Stress / long-stability / performance regression

Use `java-sdk-demo` (`references/stress-and-stability.md`) to: drive resource-cap cases (pool full,
spam), generate the long-stability (常稳) baseline load for the internal-concurrency/UAF fixes (pair
with an ASan build), and produce a pre/post-upgrade performance baseline (TPS, block interval,
latency) — the release's risk review asks for the comparison, not absolute numbers.

---

## Design rule — stable methodology vs. per-release facts

This skill deliberately encodes the **method**, not this-or-that release's facts. Per-release
specifics drift; re-derive them each time instead of trusting a baked-in value:

| Don't trust baked-in (re-derive) | How to re-derive |
|----------------------------------|------------------|
| Exact line that overwrites Web3 hash | `grep -rn "extraTransactionHash.assign\|mutableInner().extraTransactionHash" bcos-rpc/` |
| FIB → PR → commit list | from the current audit doc / `git log <branch>` |
| Which UT proves a given fix | `grep -rln "<symbol or FIB id>" <module>/test/` then `scripts/run_ut.sh` |
| Whether a flag/hardfork gates the fix | grep the FIB's PR / the feature-flag registry |

**Stable facts you may rely on** (wire protocol — changing them breaks chain compatibility, so they
don't move): tars `Transaction` field numbers — **2** `dataHash` (signing hash), **4** `importTime`,
**7** `sender`, **9** `type`, **10** `extraTransactionBytes`, **11** `extraTransactionHash` (the real
txHash). Default ports 30300 / 20200 / 8545.

---

## Known gotchas (verify, then trust)

- **Web3 `extraTransactionHash` is overwritten at the RPC entry.** The Web3 endpoint recomputes the
  canonical hash and writes it back onto the transaction (verify: the grep above; as of this writing
  `bcos-rpc/.../web3jsonrpc/endpoints/EthEndpoint.cpp` computes at ~:437 and assigns at ~:456). So a
  **forged-canonical-hash** case (e.g. New-1) is **Bucket C, P2P-only** — you cannot express it via
  `eth_sendRawTransaction`, the node will clobber your value. Don't burn time forging it through RPC.
- **`dataHash` (native, tars field 2) is different** — it *is* reachable via `sendTransaction`, so
  FIB-33-style "cache hash not trusted" cases are Bucket B, not C.
- **SM vs non-SM are different code paths.** Any crypto/signature fix must be tested on both suites.
- **Governance changes the config knob.** With `auth_check` on, plain `setSystemConfigByKey` is
  rejected — `compatibility_version` bumps and feature-flag toggles must go through a committee
  proposal: `setSysConfigProposal <key> <value>` then `voteProposal <id>`. Don't get stuck thinking
  the upgrade command is broken when it's really governance gating it.

---

## Bundled resources

| File | When to read |
|------|--------------|
| `scripts/cluster_up.sh` | bring up an AIR cluster and wait for RPC ready |
| `scripts/run_ut.sh` | run a module UT binary (or one case) and report pass/fail — Bucket C fallback |
| `references/rpc-paths.md` | Bucket A: BCOS RPC vs Web3 RPC, natural-language tx via Viem / console, assert recipes |
| `references/ci-harnesses.md` | ready CI suites: newman BCOS-RPC-API, Hardhat Web3 (`bcos-testing`), `ci_check_air.sh`, account funding |
| `references/byte-tampering.md` | Bucket B: tars/RLP field map and the build→flip→re-encode→inject recipe |
| `references/p2p-injection.md` | Bucket C: injector approaches and the UT-as-evidence downgrade |
| `references/console.md` | the Java console: native client + observation surface (state/config/consensus/permission) |
| `references/version-upgrade.md` | version-upgrade compatibility: rolling swap, compatibility_version, feature/hardfork gating, rollback |
| `references/permission-governance.md` | auth mode, committee voting, deploy/method authorization tests |
| `references/stress-and-stability.md` | java-sdk-demo load gen, resource-cap cases, long-stability, perf regression |
| `references/audit-qa-playbook.md` | drive testing from an audit / 提测 handover doc; produce the evidence matrix |
