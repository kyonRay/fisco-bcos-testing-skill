# Bucket C — P2P / consensus injection (and the UT-as-evidence downgrade)

The attack surface here is the P2P frame layer, block-sync messages, or consensus (PBFT) messages.
JSON-RPC cannot reach any of it. So Bucket C needs one of:

1. a **malicious-node build** — patch a node to emit crafted frames/messages, run it as the 1 faulty
   member of a 4-node group, and assert the other 3 keep producing blocks; or
2. a **raw-socket injector** — a script that connects to the P2P port (30300) and writes hand-crafted
   frame bytes; or
3. **(default fallback) run the module's decode/verify UT** as evidence. The fix authors already
   wrote a test that drives the exact path; running it is real evidence — just label it `UT-only`.

Building (1)/(2) is genuine dev work (you're coding against `P2PMessage` / the PBFT/sync codecs). If
they don't exist yet, do (3) now and flag the injector as a resource request to dev.

## Blueprint UTs (use as the spec for an injector, or run directly as evidence)

| Path | Blueprint UT (grep to confirm current location) | Module for `run_ut.sh` |
|------|------------------------------------------------|------------------------|
| P2P frame decode (truncation, oversized groupID/options) | `bcos-gateway/test/unittests/GatewayMessageTest.cpp` | `gateway` |
| Block-sync message bounds | `bcos-sync/test/.../*Sync*Test.cpp` | `sync` |
| PBFT message / proposal decode & verify | `bcos-pbft/test/.../*Test.cpp` | `pbft` |
| Web3 canonical txHash recompute (New-1) | `bcos-tars-protocol/test/unittests/protocol/New1_Web3TxHashCanonicalTest.cpp` | `tars-protocol` |

```bash
# downgrade-to-evidence example:
.claude/skills/fisco-bcos-testing/scripts/run_ut.sh gateway --run_test=GatewayMessageTest
```

## Bucket-C FIB groups → UT module (re-derive the exact case names by grep)

| Group | FIB (example) | UT module |
|-------|---------------|-----------|
| malformed P2P frame header / options | FIB-66/67 | gateway |
| zstd decompression bomb | FIB-68 | gateway / utilities |
| front payload cap | FIB-69 | front |
| block-sync message bounds | FIB-17/18/19/20, FIB-149 | sync |
| PBFT proposal repeated-field / length checks | FIB-120/123/130 | pbft |
| pre-prepare / NewView / recovery verify | FIB-124/127/131 | pbft |
| packetType bound into signature (hardfork) | FIB-134 | pbft |
| forged Web3 extraTransactionHash | New-1 | tars-protocol |

## Malicious-node group assertion (when an injector/patch exists)

Run a 4-node group (`scripts/cluster_up.sh -n 4`), make node3 the faulty one (the patched build or
the injector target), drive legal load at the other three, and assert:

- the 3 honest nodes keep advancing block height and agree on `stateRoot`;
- no honest node crashes (pair with an ASan build to surface UAF/OOB as a visible crash);
- error-log rate on honest nodes does not blow up (some fixes are specifically "don't flood error
  logs on malformed input").

This is also the home of the long-stability / 常稳 run: legal load + periodic fault injection
(restarts, view-change storms, `tc/netem` latency) over 24–72h, watching RSS / fd / TPS / stateRoot.
