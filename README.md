# fisco-bcos-testing

A [Claude Code](https://claude.com/claude-code) skill for testing the **FISCO-BCOS** blockchain
(AIR / single-process mode) end to end: stand up a local cluster, drive **both** RPC services,
classify each test by black-box reachability, tamper transaction bytes, run module unit-test binaries
as evidence, test version-upgrade compatibility and permission governance, run stress / long-stability
loads, and emit an evidence matrix.

It exists to fix one thing people keep redoing by hand — turning *"test these fixes"* or *"validate
this audit"* into a reproducible run that doesn't (a) waste hours testing things the RPC layer can't
reach, or (b) record a crash as a clean "rejection" pass.

> Status: the bundled shell scripts are syntax-checked; they have not been run end-to-end in every
> environment. Treat paths/ports as defaults and adapt to your setup.

---

## What it gives you

- **The three-bucket (三桶) reachability model** — classify every test before running it: Bucket A
  (reachable with stock SDK/console), Bucket B (needs byte-tampering at the RPC), Bucket C (P2P /
  consensus layer; falls back to running the relevant unit-test binary as evidence). Stops you from
  "black-box testing" a fix the RPC can't reach.
- **Two RPCs, kept distinct** — **BCOS RPC** (the Java console / SDK, tars-encoded) vs **Web3 RPC**
  (Viem / ethers.js / Hardhat, Ethereum JSON-RPC spec). Includes the cross-path gotchas: enabling the
  Web3 path from the BCOS console (`feature_balance`, `balance_transfer`, `web3_chain_id`, funding),
  and that the Web3 endpoint recomputes the canonical tx hash.
- **Natural-language → transaction** — describe the tx; build it with Viem (Web3) or the console (BCOS).
- **A version-upgrade compatibility track** — rolling binary swap, `compatibility_version` bump,
  feature-flag / hardfork gating, mixed-version no-fork, rollback, historical-data continuity.
- **Permission governance, stress / long-stability, and the ready CI regression suites**
  (newman BCOS-RPC-API collection, the `bcos-testing` Hardhat suite, `ci_check_air.sh`).
- **False-green guards + an evidence matrix** — every negative case pairs a positive control and a
  node-alive probe; results separate "live black-box" from "unit-test-only" evidence.
- **A "don't guess — check the docs, then the source" rule** baked into the workflow.

---

## Requirements

- **Claude Code** — the skill runs inside it.
- **A FISCO-BCOS source checkout** — the skill greps it, runs `tools/BcosAirBuilder/build_chain.sh`,
  and runs module unit-test binaries (`build/<module>/test/test-bcos-<module>`). Get it at
  <https://github.com/FISCO-BCOS/FISCO-BCOS>.
- **For live cluster testing**, a `fisco-bcos` binary (the skill offers three ways to get one —
  specify an existing path, download a release, or compile from source), plus:
  - **Node.js** — for Viem / ethers.js / Hardhat (the Web3 RPC path).
  - **JDK 11+** — for the Java console and `java-sdk-demo` (the BCOS RPC path and stress testing).

The skill works without a running cluster too: Bucket C / internal-concurrency fixes fall back to
running the relevant unit-test binary as evidence.

---

## Install

A Claude Code skill is a folder that Claude Code auto-discovers. Put this folder in one of:

- **Per-project** (recommended) — `<your-FISCO-BCOS-checkout>/.claude/skills/fisco-bcos-testing/`.
  It then triggers only when you work in that repo.
- **Global** (all projects) — `~/.claude/skills/fisco-bcos-testing/`.

```bash
git clone <this-repo-url> fisco-bcos-testing

# project-scoped:
mkdir -p /path/to/FISCO-BCOS/.claude/skills
cp -r fisco-bcos-testing /path/to/FISCO-BCOS/.claude/skills/

# or global:
mkdir -p ~/.claude/skills
cp -r fisco-bcos-testing ~/.claude/skills/
```

Open (or restart) Claude Code in the target repo. The skill appears in the available-skills list
automatically; no registration step.

---

## Use

Describe a testing task in natural language while working in a FISCO-BCOS checkout — Claude invokes
the skill when the task matches. Examples:

- `test the FIB-33 fix` · `测一下 FIB-33 的修复`
- `spin up a 4-node chain and send a Web3 transaction with Viem`
- `verify the 3.16 → 3.17 upgrade compatibility, watch for forks`
- `run this QA handover doc and produce an evidence matrix`
- `build a transaction with a tampered dataHash and check the node rejects it`
- `enable permission governance and confirm an unauthorized deploy is denied`

You can also be explicit: *"use the fisco-bcos-testing skill to …"*.

When it triggers, Claude announces it and follows `SKILL.md`: frame the request → bring up a cluster →
classify by bucket → execute → apply false-green guards → emit the evidence matrix, plus the
operational dimensions (version-upgrade, governance, stress) when relevant.

If no `fisco-bcos` binary is found, the skill asks which to do: point at an existing binary, download
a release (released behavior only), or compile from source (required to test unreleased fixes).

---

## What's inside

```
fisco-bcos-testing/
├── SKILL.md                         the workflow Claude follows (entry point)
├── README.md                        this file
├── scripts/
│   ├── cluster_up.sh                build_chain → enable Web3 → start → wait for RPC ready
│   └── run_ut.sh                    run a module unit-test binary (Bucket C evidence)
└── references/                      loaded by Claude on demand
    ├── rpc-paths.md                 BCOS RPC vs Web3 RPC; Viem/console; enabling the Web3 path
    ├── byte-tampering.md            Bucket B: tars field map + tamper recipe
    ├── p2p-injection.md             Bucket C: injector approaches + unit-test-as-evidence
    ├── console.md                   the Java console: BCOS RPC client + observation surface
    ├── ci-harnesses.md              ready CI suites (newman / Hardhat / ci_check_air) + account funding
    ├── version-upgrade.md           upgrade compatibility: rolling swap, version bump, flag/hardfork gating
    ├── permission-governance.md     auth mode, committee voting, deploy/method authorization
    ├── stress-and-stability.md      java-sdk-demo load, resource caps, long-stability, perf regression
    └── audit-qa-playbook.md         drive testing from an audit / QA handover doc → evidence matrix
```

---

## Design principles

- **Methodology is fixed; per-release facts are inputs.** The skill encodes stable procedures (the
  bucket model, the two-RPC map, false-green guards, the upgrade procedure). Volatile specifics — a
  release's finding list, exact code line numbers, the current feature-flag names — are **re-derived
  at run time** (grep a symbol, `listSystemConfigs`, read the current handover doc), never baked in.
  This keeps the skill from rotting between releases.
- **Don't guess — escalate to the source.** On any unknown (a command's syntax, a config key, a
  return code), the workflow consults the docs, then the docs repo, then the node/console source,
  before asserting an expected result. If still unresolved, it records "unknown" rather than inventing.

---

## Scope & limits

- **AIR mode only.** MAX / Tars microservice mode is out of scope for this version.
- Tuned for FISCO-BCOS **3.x** (the two-RPC split, tars transaction layout, `compatibility_version`
  upgrade machinery, permission governance).
- The skill drives the official tooling — it assumes a FISCO-BCOS checkout and, for live testing, the
  usual toolchain (Node.js, JDK). It does not install those for you.

---

## License

This skill ships without a license — add one before publishing. FISCO-BCOS itself is Apache-2.0; a
matching `Apache-2.0` is a reasonable default.
