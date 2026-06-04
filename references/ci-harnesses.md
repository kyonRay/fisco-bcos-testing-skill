# Ready-made CI regression suites — run these before hand-writing cases

FISCO-BCOS ships regression suites that CI runs on every push
(`.github/workflows/workflow.yml` → `tools/.ci/*`). Running them is strong, low-effort black-box
evidence and they split cleanly **by RPC** — do this first, then hand-write only what they don't
cover. Re-read the current scripts (`tools/.ci/`) since arguments drift.

## The suites

| Suite | RPC | Covers | How to run |
|-------|-----|--------|------------|
| **FISCOBCOS-RPC-API** (Postman + newman) | **BCOS RPC** | the custom BCOS RPC method surface | `cd tools && bash .ci/rpcapi_ci_prepare.sh` (builds 4-node, SSL off, starts), then run the collection `https://raw.githubusercontent.com/FISCO-BCOS/FISCOBCOS-RPC-API/main/fiscobcos.rpcapi.collection.json` with `newman` |
| **bcos-testing** (Hardhat) | **Web3 RPC** | Ethereum JSON-RPC compatibility, over HTTP **and** WebSocket | `tools/.ci/web3_test.sh <account.pem>` — clones `FISCO-BCOS/bcos-testing`, writes `.env` (`PRIVATE_KEY`, `BCOS_HOST_URL=http://127.0.0.1:8545`), runs `npx hardhat test --network bcosnet` |
| **ci_check_air.sh** | both | full AIR integration: console + Java SDK + java-sdk-demo, each in **non-SM and SM**, plus a consensus/no-fork check and node expansion | `cd tools && bash .ci/ci_check_air.sh <base_ref> "true"` (2nd arg `"true"` also runs the Web3 test) |

`ci_check_air.sh` orchestrates the per-tool scripts: `console_ci_test.sh`, `java_sdk_ci_test.sh`,
`java_sdk_demo_ci_test.sh` (each invoked with `"false"` then `"true"` = non-SM then SM), and
`web3_test.sh`. It also flips `enable_web3_rpc` on (the config default is `false`).

## The cross-RPC account-funding sequence (essential)

The Web3 suite can't transact until its account has a balance — and the account is **funded through
the BCOS RPC console**, because both RPCs share one ledger/account state. This is what
`ci_check_air.sh` does before the Web3 test (lines ~256-265); reproduce it:

```bash
# in console/dist, with the chain's sdk certs + ecdsa account copied in:
bash console.sh listSystemConfigs                        # confirm feature_balance / balance_transfer / web3_chain_id are ON
account=$(bash console.sh listAccount | grep "current account" | awk -F '(' '{print $1}')
bash console.sh addBalance "${account}" 200 ether        # fund via BCOS RPC (needs feature_balance on)
bash console.sh setSystemConfigByKey tx_gas_price 1       # so Web3 txs have a workable gas price
bash console.sh getSystemConfigByKey web3_chain_id        # the chainId Viem/Hardhat must use (NOT assumed 20200)
# extract that account's hex private key from its .pem, feed Hardhat/Viem:
openssl ec -in account/ecdsa/${account}.pem -text -noout | grep -A3 'priv:' | tail -n +2 | tr -d ': \n' | sed 's/^00//'
```

Forget this step and every Web3 transaction fails with insufficient funds — and it looks like a Web3
RPC bug when it's really an un-provisioned account. This is the most common cross-path footgun.

## When to use these vs hand-written cases

- **Positive regression / RPC-method coverage** → these suites already do it; run them as the Bucket A
  baseline and as the "正向回归 / no functional regression" evidence.
- **Security negative cases (forged/malformed input)** → not covered here; hand-write per
  `byte-tampering.md` / `p2p-injection.md`.
- **Version-upgrade** → run these suites *before and after* the upgrade as the compatibility check.
