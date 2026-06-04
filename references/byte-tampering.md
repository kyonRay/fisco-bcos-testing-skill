# Bucket B — byte-tampering at the RPC entry

## Why the SDK can't do this for you

ethers / web3j / the BCOS SDK always compute the hash from the content. They physically cannot
express "content changed, hash unchanged" or "type set to an unknown value" — they'd just produce a
*consistent* transaction. To test that the node **recomputes/validates** instead of trusting a
client-supplied field, you must edit the encoded struct after signing and before sending, then inject
the raw hex through `curl` (BCOS RPC `sendTransaction`, see `rpc-paths.md`).

## tars `Transaction` field map (stable wire protocol — safe to rely on)

From `bcos-tars-protocol/bcos-tars-protocol/tars/Transaction.tars`. These tags are part of the wire
format; changing them would break chain compatibility, so they don't move between releases.

```
struct TransactionData {            struct Transaction {
  1  version                          1  data            (TransactionData above)
  2  chainID                          2  dataHash        <- signing hash; FIB-33 target
  3  groupID                          3  signature
  4  blockLimit                       4  importTime      <- FIB-61 negative-value target
  5  nonce                            5  attribute
  6  to            <- FIB-73/74       7  sender          <- FIB-34 prefill target
  7  input                            8  extraData
  8  abi                              9  type            <- FIB-35 unknown-type target
  9  value                            10 extraTransactionBytes
  10 gasPrice                         11 extraTransactionHash  <- real txHash; OVERWRITTEN on Web3 RPC
  11 gasLimit                       }
  12 maxFeePerGas
  13 maxPriorityFeePerGas
  14 extension
};
```

## The recipe

1. **Build a valid, signed tx** with the SDK (or a tiny C++ helper that links `bcos-tars-protocol`).
   The SDK computes `dataHash` (field 2) at build time.
2. **Decode → flip exactly one field → re-encode.** Easiest in a small C++ helper using the same tars
   structs: deserialize the bytes, mutate one field, serialize again. (Editing raw tars bytes by hand
   is error-prone — prefer the struct round-trip.)
3. **Inject** the resulting hex through `curl` to native `sendTransaction`.
4. **Assert** rejection (verify/signature error code, not on-chain) **+ node alive** (Step 5 guard).

## Per-FIB tamper table

| Case | FIB / PR | Field to flip | Expected |
|------|----------|---------------|----------|
| cache hash not trusted | FIB-33 / #5077 | `Transaction.dataHash` (2) → wrong value | node recomputes, signature check fails, rejected |
| prefilled sender no bypass | FIB-34 / #5078 | set `Transaction.sender` (7) + a bad signature | full verify still runs, rejected |
| unknown tx type no bypass | FIB-35 / #5079 | `Transaction.type` (9) → unknown value | rejected by type, no signature-binding bypass |
| malformed `to` | FIB-73/74 / #5111 | `TransactionData.to` (6) → illegal length | no uninitialized-address / nondeterminism; all nodes agree |
| negative importTime | FIB-61 | `Transaction.importTime` (4) → negative | no unsigned overflow; rejected/handled |

## The Web3 hash-forgery trap

Do **not** try FIB-New-1 (forged `extraTransactionHash`) through `eth_sendRawTransaction`. The Web3
endpoint recomputes the canonical hash and assigns it back onto the tx, clobbering whatever you sent
(verify: `grep -rn "extraTransactionHash.assign\|mutableInner().extraTransactionHash" bcos-rpc/`).
That makes New-1 **Bucket C (P2P-only)** — see `p2p-injection.md`. By contrast `dataHash` (native,
field 2) is *not* clobbered, so FIB-33 stays Bucket B.

## Fastest evidence when a tamper helper isn't ready

The fixes ship UTs that already inject forged bytes — run them as evidence (UT-only) and pair with a
Bucket A positive control. Find them by symbol:

```bash
grep -rln "fake(32\|dataHash\|extraTransactionHash" bcos-txpool/test bcos-tars-protocol/test
# then, e.g.:
.claude/skills/fisco-bcos-testing/scripts/run_ut.sh tars-protocol --run_test=New1_Web3TxHashCanonicalTest
```
