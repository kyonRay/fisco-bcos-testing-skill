# Stress testing, long-stability, and performance regression

The official load generator is **java-sdk-demo** (`github.com/FISCO-BCOS/java-sdk-demo`, build with
`bash gradlew build`). It drives the BCOS RPC at high QPS — use it for three jobs: Bucket A
resource-exhaustion cases, the long-stability (常稳) baseline load, and pre/post performance
regression.

Source: `operation_and_maintenance/stress_testing.md`.

## Setup

1. Build the demo (`gradlew build`), copy the chain's `sdk/` certs into `dist/conf/`, point
   `dist/conf/config.toml` `[network] peers` at all node RPC ports (`127.0.0.1:20200..20203`).
2. **Tune the nodes for load** (else you measure the wrong limit):
   - `config.genesis`: `block_tx_count_limit` up (e.g. 2000) — but for a *pool-cap* test you do the
     opposite (see below).
   - `config.ini` `[txpool] limit` must exceed your total tx count, or you hit `txpoolIsFull`
     (default 15000). For pool-cap testing this is the knob you deliberately constrain.
   - `[rpc] disable_ssl=true`, `thread_count = CPU cores`, log level `INFO`.
   - Build the node **Release** (`-DCMAKE_BUILD_TYPE=Release`) for representative numbers.

## Load programs (`java -cp 'conf/:lib/*:apps/*' org.fisco.bcos.sdk.demo.perf.<Class> <args>`)

| Class | Args | Use |
|-------|------|-----|
| `PerformanceDMC` | `<groupId> <userCount> <count> <qps>` | parallel transfer (in-contract) — main throughput |
| `PerformanceTransferDMC` | `<groupId> <userCount> <count> <qps>` | cross-contract parallel transfer |
| `PerformanceOk` | `<count> <tps> <groupId>` | serial transfer |
| `ParallelOkPerf` | `<parallelok\|precompiled> <groupId> <add\|transfer> <count> <tps> <file>` | parallel add/transfer |
| `PerformanceSmallBank` | `<groupId> <solidity\|precompiled> <add\|transfer> <contractsNum> <count> <qps> <file> <parallel>` | SmallBank, DAG on/off |
| `PerformanceCpuHeavy` | `<groupId> … <parallel> <sortSize>` | CPU-bound parallelism |
| `PerformanceKVTable` | `<count> <tps> <groupId> <useKVTable> <valueLength>` | storage KV |

Example (deploy 32 accounts, 500k txs at 20k QPS): `… PerformanceDMC group 32 500000 20000`.

## Job 1 — Bucket A resource cases

- **txpool cap (RES-02 / FIB-55):** set `[txpool] limit` *low*, then over-submit past it with a high
  `count`. Assert: excess rejected (`txpoolIsFull`), `getPendingTxSize` stays bounded, RSS doesn't
  grow unbounded, node stays alive.
- **system-address spam (RES-01 / FIB-43):** drive load at system addresses; assert classification
  stays authorization-bound, throughput of normal txs not collapsed.
- **scheduler result/view limiting (RES-07 / FIB-103):** sustained block execution + monitor RSS;
  assert bounded by the pending-results cap.

## Job 2 — long-stability (常稳) baseline

Run a steady legal load (e.g. `PerformanceDMC` at a sustainable QPS) for 24–72h while periodically
injecting faults from `p2p-injection.md` (restarts, view-change storms, `tc/netem` latency,
malformed-message bursts). This is the only black-box evidence for the internal-concurrency / UAF /
lock fixes. Pair with an **ASan build** so a latent use-after-free surfaces as a visible crash.

Monitor: process alive, RSS (flat, no monotonic growth), fd/socket count (no leak), TPS & block
interval (no sustained decay), per-node stateRoot/height (agree), error-log rate (no spike). Pass =
no crash, no deadlock/stall, no leak, no fork, ASan clean.

## Job 3 — performance regression (and hardfork cost)

The release's risk section asks for a before/after baseline, not absolute numbers:
- Same topology, same load, **pre-upgrade vs post-upgrade**: TPS, block interval, tx-confirm latency,
  sync rate. Expect no significant regression (added checks / tightened locks are usually neutral or
  positive).
- **Hardfork on/off** (FIB-134): consensus throughput with the packetType-signing flag off vs on.
- Watch the three hot spots: txpool high-concurrency, PBFT verify, scheduler parallelism.
