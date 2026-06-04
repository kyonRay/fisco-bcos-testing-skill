# Version-upgrade compatibility (the dimension that's orthogonal to the buckets)

The 三桶 model (input reachability) does not cover the highest-risk thing in a release: **does the
upgrade itself stay compatible?** A node binary can be flawless in isolation and still fork the chain
during a rolling upgrade, or silently fail to enable a fix because the chain data version wasn't
bumped. Test this as its own track.

Source: `operation_and_maintenance/upgrade.md`. Mechanism facts below are doc-derived and fairly
stable; the **list of feature/bugfix flag names drifts every release** — re-derive it (see below),
don't trust any baked-in list.

## The two upgrade modes — test both

| Mode | What you do | Effect | Enables new features? |
|------|-------------|--------|-----------------------|
| **A. Binary-only** | stop node → replace `fisco-bcos` binary → restart | bug/stability/perf fixes | **No** — chain keeps running with the *old* `compatibility_version` logic |
| **B. Data-version bump** | after *all* binaries upgraded, send a tx: `setSystemConfigByKey compatibility_version 3.x.x` | turns on the new version's behavior/features | **Yes** |

The trap: a fix that is gated behind a data version (or a feature flag) does **nothing** after a
binary-only upgrade. If you test such a fix without bumping the version, you get a false negative
("the fix doesn't work") — or worse, a false positive if you think binary-only was enough.

## Core test 1 — mixed-version window (no-fork)

This is the single most important upgrade test. Replace binaries one node at a time (gray/rolling),
**not** all at once, and prove the chain survives the window where old and new binaries coexist.

```
4-node group on old version, producing blocks under steady load (java-sdk-demo, see stress-and-stability.md)
  → stop node3, swap binary to new version, restart node3
  → assert: all 4 nodes keep advancing height and AGREE on block hash / stateRoot (no fork)
  → repeat for node2, node1, node0
  → only after ALL nodes are new: setSystemConfigByKey compatibility_version <new>
  → assert: chain continues, new behavior now active
```

Observe with the console (see `console.md`): `getBlockNumber`, `getSyncStatus`, `getConsensusStatus`
on **every** node — they must not diverge. Back up each node's ledger `data/` before swapping (the
doc's mandatory rollback safeguard).

**This is exactly where an audit hardfork bites.** FIB-134 (packetType bound into the PBFT
signature) changes the signed wire format. If it activates per-node instead of consistently, mixed
old/new nodes fail to verify each other and the group stalls. Test: confirm that during the
binary-only window (before the version/flag is set) old and new still consense; and that once the
gating flag is set, it must be set on the **whole group** — a single un-upgraded/un-flagged node
should be expected to fall out, not silently corrupt consensus.

## Core test 2 — feature flags / bugfix gating (on/off)

New behavior is gated by system-config flags set through the console. The general mechanism (stable):

```
[group0]: /apps> getSystemConfigByKey compatibility_version      # check current data version
[group0]: /apps> setSystemConfigByKey <featureName>              # enable a bugfix/feature
```

From 3.6.x, setting `compatibility_version` auto-enables all bugfixes whose min-version ≤ the set
version. So "flag off" = old chain version / not set; "flag on" = flag set or version bumped past it.

**Re-derive the current flag list — do not trust a baked-in table.** The names change per release.
The authoritative enumerator is the console:

```
[group0]: /apps> listSystemConfigs     # dumps every key: Config | Value | Enable Block
```

Read it directly: `Value = null` (or `0`) means off; a set Value with `Enable Block ≤` current height
means active from that block. Real names seen on a 3.15.x chain include `bugfix_nonce_not_increase_when_revert`,
`bugfix_delegatecall_transfer` (was `null` = off), `bugfix_evm_exception_gas_used`,
`bugfix_internal_create_permission_denied`, `feature_balance`, `feature_evm_cancun`,
`feature_rpbft`, `web3_chain_id`, `compatibility_version`. To map a FIB to its flag, cross-check the
FIB's PR against this list (or `grep -rn "bugfix_\|feature_" bcos-framework/`).

The audit's feature-gated fixes are toggled by exactly this machinery. For each: assert the behavior
difference the FIB describes in **both** states — off on an un-bumped chain, on after
`setSystemConfigByKey <flag>` / a `compatibility_version` bump.

## Core test 3 — rollback

The doc mandates a rollback path (backup ledger before upgrade). Test it: from an upgraded node, stop
→ restore the backed-up `data/` + old binary → restart → assert the node rejoins and the chain reads.
Note the asymmetry the doc implies: **binary/flag changes that are not yet version-locked can roll
back; a data-version bump or an activated hardfork generally cannot** (a rolled-back single node will
fail verification against the already-advanced group). State which of your release's changes are
reversible in the evidence matrix.

## Core test 4 — historical data continuity

After upgrade, assert pre-upgrade blocks/state are still readable: `getBlockByNumber <old-height>`,
`getTransactionReceipt <old-tx-hash>`, and a `call` reading state written before the upgrade. The doc
states no storage-schema change is expected — verify that holds.

## Governance interaction (don't get blocked by it)

If permission governance (`auth_check`) is on, `setSystemConfigByKey` is rejected — version/feature
changes must go through a committee proposal: `setSysConfigProposal compatibility_version 3.x.x` then
`voteProposal <id>` to threshold. See `permission-governance.md`. Plan upgrade tests on a governance
chain accordingly, or test on a non-governance chain first to isolate the upgrade mechanics.

## Upgrade test matrix (fill per release)

| Check | Tool | Pass criterion |
|-------|------|----------------|
| mixed old/new window | rolling binary swap + console on all nodes | height advances, no stateRoot/blockhash divergence |
| binary-only ≠ feature-on | console `getSystemConfigByKey` | gated fix inactive until version/flag set |
| each feature flag off→on | console `setSystemConfigByKey` | behavior matches FIB description in both states |
| hardfork consistency (FIB-134) | whole-group enable | group consenses when uniformly enabled; mismatched node falls out, no corruption |
| rollback | restore backup + old binary | reversible changes roll back; irreversibles documented |
| historical data | console `getBlockByNumber` / `getTransactionReceipt` / `call` | pre-upgrade data readable |
| 2.x→3.x (if in scope) | data-replay / app-adaptation / cross-chain | per doc §3 — usually out of a 3.x point-release's scope |
