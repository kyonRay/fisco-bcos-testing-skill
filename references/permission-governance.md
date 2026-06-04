# Permission governance — testing deploy/method authorization fixes

FISCO-BCOS 3.x has contract-granularity permission governance: a committee votes to manage who can
deploy contracts and call specific methods. Several audit fixes live here (deploy authorization,
auth-failure handling, system-tx authorization), so testing them requires a **governance-enabled
chain**, not the default one.

Source: `operation_and_maintenance/committee_usage.md`.

## Enable governance

- **At build time:** `build_chain.sh ... -A` (auto-generate the initial admin account into the
  chain's `ca/accounts/`) or `-a <account-address>` (use a specific, *verified-to-exist* address).
  3.3+ defaults auth mode on. This sets, in `config.genesis`:
  `[executor] is_auth_check=true` and `auth_admin_account=0x...`.
- **Dynamically (3.3+):** bump data version to ≥3.3.0, then in the console:
  `initAuth <admin-addr>` → `getCommitteeInfo` (confirm) → `setSystemConfigByKey auth_check_status 1`.

`cluster_up.sh` doesn't enable auth by default — for these tests, run `build_chain.sh` directly with
`-A`/`-a`, or pass the flag through.

## Committee & voting model (console)

- `getCommitteeInfo` (committee + proposalMgr addresses, governors, weights, participate/win rates)
- `getCurrentAccount`, `loadAccount <addr>` (switch the acting account)
- `updateGovernorProposal <addr> <weight>` (weight 0 = remove a governor)
- `setRateProposal <participateRate> <winRate>`
- `voteProposal <id>` (a proposal needs threshold; single governor with 0/0 thresholds passes
  immediately)

When >1 governor and thresholds are set, a proposal sits at `notEnoughVotes` until enough governors
`voteProposal` it to `finished`.

## Deploy authorization

- `setDeployAuthTypeProposal white_list|black_list` then vote → global deploy policy
- `getDeployAuth` (current policy), `checkDeployAuth` (acting account's deploy right)
- `openDeployAuthProposal <addr>` / `closeDeployAuthProposal <addr>` then vote
- `getContractAdmin <contract-addr>`

## Method authorization

- `setMethodAuth <contract-addr> "set(string)" white_list` (admin sets a method policy)
- `checkMethodAuth <contract-addr> "set(string)"`
- `openMethodAuth <contract-addr> "set(string)" <addr>`

## Testing the audit's authorization fixes

The pattern is always: **negative (unauthorized → denied) + positive control (authorized → success)
+ node alive**.

| Fix area | Test | Pass |
|----------|------|------|
| deploy authorization (CREATE2 deploy auth) | with white-list policy, deploy from an un-permitted account | `Permission denied`, **return code 18**, no contract created |
| auth-failure doesn't leak input / false-success | trigger a denied call, inspect revert output | output does **not** echo full tx input; not reported as success |
| system-tx authorization | drive txs at system addresses under auth mode | classification stays authorization-bound |
| positive control | grant via `openDeployAuthProposal`/`openMethodAuth`, retry | now succeeds (status 0) |

Observe results with the console (`deploy`/`call` print `transaction status` + receipt message; see
`console.md`).

## Governance × upgrade gotcha

With `auth_check` on, plain `setSystemConfigByKey` is rejected — system-config and version/feature
changes must go through the committee: `setSysConfigProposal <key> <value>` then `voteProposal <id>`.
This directly affects upgrade testing (`version-upgrade.md`): on a governance chain, the
`compatibility_version` bump and feature-flag enablement are committee proposals, not direct sets.
