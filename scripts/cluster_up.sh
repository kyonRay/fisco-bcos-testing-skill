#!/usr/bin/env bash
# Bring up a local N-node FISCO-BCOS AIR cluster and wait until RPC actually answers.
#
# Wraps:  build_chain.sh (generate)  ->  start_all.sh (launch)  ->  poll Web3 RPC (ready)
#
# Usage:
#   cluster_up.sh [-n NODES] [-e FISCO_BIN] [-o OUTDIR] [-p P2P,RPC] [-s] [-d] [-h]
#     -n  node count            (default 4)
#     -e  fisco-bcos binary     (default: build/fisco-bcos-air/fisco-bcos under repo root)
#     -o  output dir            (default ./nodes-test)
#     -p  start ports "P2P,RPC" (default 30300,20200; Web3 RPC = RPC offset, node0 = 8545 by config)
#     -s  SM (国密) mode
#     -d  download a RELEASE binary via build_chain (omits -e). Released behavior only — a release
#         binary has NO unreleased/unmerged fixes; for those, compile from source and use -e.
#     -h  help
#
# Tear down later with:  <OUTDIR>/127.0.0.1/stop_all.sh
set -euo pipefail

NODES=4
OUTDIR="./nodes-test"
PORTS="30300,20200"
SM_FLAG=""
FISCO_BIN=""
DOWNLOAD=0

while getopts "n:e:o:p:sdh" opt; do
  case "$opt" in
    n) NODES="$OPTARG" ;;
    e) FISCO_BIN="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    p) PORTS="$OPTARG" ;;
    s) SM_FLAG="-s" ;;
    d) DOWNLOAD=1 ;;
    h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bad flag; -h for help" >&2; exit 2 ;;
  esac
done

# Locate repo root (dir containing tools/BcosAirBuilder/build_chain.sh), starting from CWD upward.
find_repo_root() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/tools/BcosAirBuilder/build_chain.sh" ] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}
REPO_ROOT="$(find_repo_root)" || { echo "ERROR: not inside a FISCO-BCOS checkout (no tools/BcosAirBuilder/build_chain.sh found)" >&2; exit 1; }
BUILD_CHAIN="$REPO_ROOT/tools/BcosAirBuilder/build_chain.sh"
if [ "$DOWNLOAD" = 1 ]; then
  echo ">> download mode: build_chain will fetch an official RELEASE binary (NO unreleased/unmerged fixes)"
else
  [ -z "$FISCO_BIN" ] && FISCO_BIN="$REPO_ROOT/build/fisco-bcos-air/fisco-bcos"
  if [ ! -x "$FISCO_BIN" ]; then
    cat >&2 <<EOF
ERROR: fisco-bcos binary not found: $FISCO_BIN
Pick one (don't guess — ask the user which):
  1) specify an existing binary:  cluster_up.sh -e /path/to/fisco-bcos ...
  2) download a release binary:   cluster_up.sh -d ...        (released behavior only)
     quick-start: https://fisco-bcos-doc.readthedocs.io/zh-cn/latest/docs/quick_start/air_installation.html
  3) compile from source:         clone https://github.com/FISCO-BCOS/FISCO-BCOS and build,
                                  then  cluster_up.sh -e build/fisco-bcos-air/fisco-bcos ...
NOTE: to test an UNRELEASED/unmerged fix, use 1 (a branch build) or 3 — a release binary won't have it.
EOF
    exit 1
  fi
fi

# '[f]isco-bcos', not 'fisco-bcos': this script's own path contains "fisco-bcos" (it lives under
# .claude/skills/fisco-bcos-testing/), so a plain -f pattern matches the running script itself and
# warns about a port clash on every single invocation, including the very first.
if pgrep -fl '[f]isco-bcos' >/dev/null 2>&1; then
  echo "WARNING: a fisco-bcos process is already running. Stop it first or use a different -o/-p to avoid port clashes." >&2
fi

echo ">> generating $NODES-node AIR cluster into $OUTDIR (ports $PORTS${SM_FLAG:+ , SM})"
if [ "$DOWNLOAD" = 1 ]; then
  bash "$BUILD_CHAIN" -p "$PORTS" -l "127.0.0.1:$NODES" -o "$OUTDIR" $SM_FLAG
else
  bash "$BUILD_CHAIN" -p "$PORTS" -l "127.0.0.1:$NODES" -o "$OUTDIR" -e "$FISCO_BIN" $SM_FLAG
fi

# Enable the Web3 RPC on every node — the generated config defaults to [web3_rpc] enable=false,
# and the readiness probe (and any Ethereum-tool testing) needs :8545. Mirrors what CI does.
#
# build_chain writes the SAME listen_port (8545) into EVERY node's [web3_rpc] block — it only
# increments the P2P and native-RPC ports, because the Web3 service ships disabled and never binds.
# Enabling it on all nodes without renumbering therefore kills every node but the first with
# "acceptor bind failed" (HttpServer.cpp). Renumber as we enable: node<i> gets WEB3_BASE+i, the
# same convention the native RPC port already follows.
WEB3_BASE=8545
echo ">> enabling Web3 RPC ([web3_rpc] enable=true, port $WEB3_BASE+i) on all nodes"
for cfg in "$OUTDIR"/127.0.0.1/node*/config.ini; do
  [ -f "$cfg" ] || continue
  idx="$(basename "$(dirname "$cfg")")"; idx="${idx#node}"
  WEB3_PORT_VAL="$((WEB3_BASE + idx))" perl -p -i -e '
    if (/^\s*\[/) { $f = /^\s*\[web3_rpc\]/ ? 1 : 0 }
    elsif ($f) {
      s/enable\s*=\s*false/enable=true/i;
      s/(listen_port\s*=\s*)\d+/$1$ENV{WEB3_PORT_VAL}/;
    }' "$cfg"
done

START="$OUTDIR/127.0.0.1/start_all.sh"
[ -f "$START" ] || { echo "ERROR: expected $START after generation, not found" >&2; exit 1; }
echo ">> starting nodes"
bash "$START"

# start_all.sh prints per-node success/failure but exits 0 either way, and the readiness probe
# below only ever talks to node0 — so a partially-started cluster (one bad port, one crashed node)
# would be reported as "cluster UP" while consensus can never reach quorum. Count the live node
# processes ourselves before believing it.
NODE_ROOT="$(cd "$OUTDIR/127.0.0.1" && pwd)"
started=0
for i in $(seq 1 15); do
  started="$(pgrep -f "$NODE_ROOT/node" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$started" -ge "$NODES" ] && break
  sleep 1
done
if [ "$started" -lt "$NODES" ]; then
  echo "ERROR: only $started of $NODES nodes are running after start_all — refusing to report a degraded cluster as UP." >&2
  echo "       Most common cause is a listen-port clash. Last error line per node:" >&2
  for out in "$NODE_ROOT"/node*/nohup.out; do
    [ -f "$out" ] || continue
    echo "         $(dirname "$out" | xargs basename): $(grep -iE 'bind failed|error:' "$out" | tail -1)" >&2
  done
  exit 1
fi
echo ">> $started/$NODES nodes running"

# Readiness: poll the node0 Web3 RPC until eth_blockNumber returns a JSON result (not conn-refused).
# Web3 port for node0 defaults to 8545 in the generated config; native RPC is the -p RPC base.
RPC_BASE="${PORTS##*,}"
WEB3_PORT=8545
echo ">> waiting for RPC to answer (Web3 :$WEB3_PORT, native :$RPC_BASE) ..."
ready=0
for i in $(seq 1 60); do
  resp="$(curl -s -m 2 -X POST "http://127.0.0.1:$WEB3_PORT" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)"
  if echo "$resp" | grep -q '"result"'; then ready=1; break; fi
  sleep 1
done

if [ "$ready" = 1 ]; then
  echo ">> cluster UP. Web3 http://127.0.0.1:$WEB3_PORT (chainId 20200) | native http://127.0.0.1:$RPC_BASE"
  echo ">> stop with: $OUTDIR/127.0.0.1/stop_all.sh"
else
  echo "ERROR: RPC did not answer within 60s. Check $OUTDIR/127.0.0.1/node0/nohup.out and log/" >&2
  exit 1
fi
