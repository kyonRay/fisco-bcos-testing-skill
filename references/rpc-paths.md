# The two RPCs — BCOS RPC vs Web3 RPC (Bucket A)

FISCO-BCOS exposes **two different RPC services with different interface specs**. They are not
interchangeable — a test written for one does not transfer to the other, and most fixes are reachable
through only one of them. **Decide which RPC a fix lives on before testing it.**

| | **BCOS RPC** | **Web3 RPC** |
|--|--------------|--------------|
| Spec | FISCO-BCOS's own interface | Ethereum JSON-RPC spec |
| Methods | `sendTransaction`, `call`, `getTransactionReceipt`, `getBlockByNumber`, `getSystemConfigByKey`, … | `eth_sendRawTransaction`, `eth_call`, `eth_getTransactionReceipt`, `eth_chainId`, `eth_getTransactionCount`, `eth_getBalance`, … |
| Wire format | tars-encoded `bcostars::Transaction` hex | Ethereum RLP hex |
| Port (node0) | **20200** | **8545** (config default `[web3_rpc] enable=false` — must enable; `cluster_up.sh` does) |
| Clients | **Java console**, Java/cpp SDK | **Viem**, ethers.js v6, web3.js, Hardhat — any Ethereum tool |
| Which fixes | native tx validation, tars-field tampering (FIB-33 `dataHash`), system-config/upgrade | Ethereum-compat behavior, RLP decoding, canonical txHash (New-1) |

**Cross-path dependency you must know:** both RPCs share one ledger and account state. The Web3 path
isn't usable until you turn it on **from the BCOS RPC console** — enable the balance model + Web3
chain id (system configs, below), then fund the account (`addBalance`). Skipping this makes every Web3
tx fail (insufficient funds / wrong chainId) and look like a Web3 bug.

### Enable the Web3 path first (one-time, from the console / BCOS RPC)

A fresh chain rejects Web3 transactions until these **system configs** are on. Set them in the console
(`setSystemConfigByKey <key> <value>`), or on a governance chain via `setSysConfigProposal` +
`voteProposal`. Dump the current state any time with **`listSystemConfigs`** (shows Value + Enable
Block for every key).

| System config | Why the Web3 path needs it |
|---------------|----------------------------|
| `feature_balance` (+ `feature_balance_precompiled`, `feature_balance_policy1`) | the native account-balance model, so accounts can hold/transfer ether |
| `balance_transfer` | allow value transfer between accounts |
| `web3_chain_id` | the chainId Ethereum tools must use — **query it, do NOT assume 20200** (it's a config; one chain showed `60600`) |
| `tx_gas_price` | a workable gas price for Web3 txs (CI sets it to `1`) |

Then `addBalance <account> 200 ether` (see `ci-harnesses.md`). Verify with `listSystemConfigs`: each
key should show a non-`null` Value and an Enable Block ≤ current height.

---

## Natural-language → transaction (the AI-driven method)

You don't hand-assemble these. State the intent in natural language and let the tool build the tx —
**Viem for the Web3 RPC, the console for the BCOS RPC.** This is the fast path for both a human tester
and an AI driving the test: describe the transaction, generate the snippet/commands, run, read result.

### Web3 RPC — Viem (modern, recommended) or ethers.js

Intent: *"from my funded account, send 0.1 ether to 0xBob and confirm it mined."*

```js
// npm i viem ; node this.mjs
import { createWalletClient, createPublicClient, http, defineChain, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";

// chainId is the system config `web3_chain_id` — QUERY it, don't assume:
//   console> getSystemConfigByKey web3_chain_id     (or listSystemConfigs)
const CHAIN_ID = 20200; // <- replace with the value you queried (e.g. 60600 on some chains)
const bcos = defineChain({ id: CHAIN_ID, name: "fisco-bcos",
  nativeCurrency: { name: "ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } } });

const account = privateKeyToAccount("0x<32-byte-key>");            // key funded via console (see above)
const wallet  = createWalletClient({ account, chain: bcos, transport: http() });
const pub     = createPublicClient({ chain: bcos, transport: http() });

const hash = await wallet.sendTransaction({ to: "0xBob", value: parseEther("0.1") });
const rcpt = await pub.waitForTransactionReceipt({ hash });
console.log("status", rcpt.status, "block", rcpt.blockNumber);     // expect status "success"
console.log("alive", await pub.getBlockNumber());                  // node-alive probe
```

ethers.js v6 is equivalent (`JsonRpcProvider("http://127.0.0.1:8545")` + `Wallet`); use whichever the
team prefers. For a whole ready-made Web3 regression suite, use the Hardhat project in
`ci-harnesses.md` instead of writing your own.

### BCOS RPC — the console

Intent: *"deploy HelloWorld, call set('hi'), read it back."*

```
[group0]: /apps> deploy HelloWorld
[group0]: /apps> call HelloWorld <address> set "hi"
[group0]: /apps> call HelloWorld <address> get
```

The console builds, signs, and tars-encodes the tx for you and prints `transaction status` + receipt.
Full command set and the observation commands (`getSyncStatus`, `getConsensusStatus`, `getPendingTxSize`,
`getSystemConfigByKey`, …) are in `console.md`. Reserve raw `curl` for Bucket B (injecting tampered
tars hex the console would never build — see `byte-tampering.md`).

---

## What to assert (observable behavior, either RPC)

| Test intent | Assert on |
|-------------|-----------|
| legal tx on-chain | receipt `status`/`status==1`, block advanced |
| gas charged correctly | receipt `gasUsed` vs expectation (e.g. new storage slot fully charged) |
| auth / deploy denied | status != success (BCOS return code **18**), no state change, **node alive** |
| nonce replay / dedup | second submit with same nonce rejected |
| pool-full / rate limit | sustained over-submit eventually rejected; `getPendingTxSize` bounded; RSS flat |
| internal error reported truthfully | receipt error type not mislabeled as OutOfGas |

Every negative case needs its positive control + a node-alive probe (SKILL.md Step 5).
