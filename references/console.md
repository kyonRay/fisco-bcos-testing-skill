# The FISCO-BCOS console — the canonical BCOS RPC client & observation surface

The Java console is the official black-box client for the **BCOS RPC** (FISCO-BCOS's own interface,
not the Ethereum-spec Web3 RPC) and the node's primary
observation surface. Use it for: legal deploy/call (Bucket A), reading consensus/sync/pool state
(observing fixes you can't trigger directly), and driving system-config / upgrade / permission
operations. Reserve raw `curl` for Bucket B (injecting tampered tars hex) — the console always builds
well-formed transactions.

Source: `operation_and_maintenance/console/console_commands.md`. Connect to the node by copying the
chain's `sdk/` certs into the console's `conf/` (same certs the SDK uses).

## Command groups

**Contract (Bucket A execution):**
- `deploy <Contract> [args...]` → returns contract address (or `Permission denied`, return code 18)
- `call <Contract> <address> <method> [args...]` → prints `transaction status`, receipt message
- `getCode <address>`, `listAbi <Contract>`, `getDeployLog`, `listDeployContractAddress`

**State / observation (how you watch fixes that aren't directly triggerable):**
- `getBlockNumber` — node-alive probe + height-advance check
- `getSyncStatus` — peer sync state; watch for poisoning / divergence (sync-resilience FIBs)
- `getPeers`, `getBlockByNumber <n> [true]`, `getBlockByHash`, `getBlockHashByNumber`
- `getTransactionByHash <hash>`, `getTransactionReceipt <hash>` — status, gasUsed, output
- `getPendingTxSize` — txpool depth; watch under pool-cap / rate-limit tests
- `getTotalTransactionCount`

**System config (upgrade, feature flags, Web3 enablement — see version-upgrade.md):**
- `listSystemConfigs` — **dump every config** with its Value and Enable Block (the fastest way to see
  what's on and to enumerate the current `bugfix_*` / `feature_*` flag names)
- `getSystemConfigByKey <key>` / `setSystemConfigByKey <key> <value>`
- keys include: `compatibility_version`, `tx_count_limit`, `tx_gas_price`, `tx_gas_limit`,
  `consensus_leader_period`, `auth_check_status`, `web3_chain_id`, `feature_balance`,
  `feature_balance_precompiled`, `balance_transfer`, and per-release `bugfix_*` / `feature_*` flags
- account funding (needs `feature_balance` on): `addBalance <account> <amount> ether`

> Web3 prerequisite: enable `feature_balance` (+ `feature_balance_precompiled` / `feature_balance_policy1`),
> `balance_transfer`, `web3_chain_id`, `tx_gas_price`, then `addBalance` — see `rpc-paths.md`.

**Consensus (observe consensus-resilience fixes):**
- `getSealerList`, `getObserverList`, `getPbftView`, `getConsensusStatus`

**Permission (only present when the node has governance on — see permission-governance.md):**
- `getCommitteeInfo`, `getCurrentAccount`, `loadAccount`, `voteProposal`, `setDeployAuthTypeProposal`,
  `checkDeployAuth`, `setMethodAuth`, `checkMethodAuth`, …

## Mapping observations to fix areas

| You want to check | Console command(s) | Pass signal |
|-------------------|--------------------|-------------|
| node didn't crash on a negative case | `getBlockNumber` (repeat) | height keeps advancing |
| sync poisoning didn't corrupt state | `getSyncStatus` on all nodes | consistent, no rollback/divergence |
| consensus healthy after attack injection | `getConsensusStatus`, `getPbftView` | view stable, all nodes agree |
| txpool bounded under flood | `getPendingTxSize` | bounded, not unbounded growth |
| auth fix denies unauthorized op | `deploy` / `call` | `Permission denied`, return/status **18** |
| upgrade data version active | `getSystemConfigByKey compatibility_version` | equals the target version |

## Status codes

`transaction status: 0` / return code 0 = success. **Return code 18 = Permission denied** (auth-mode
rejection). Use the receipt status as the assertion for auth and execution-correctness cases.
