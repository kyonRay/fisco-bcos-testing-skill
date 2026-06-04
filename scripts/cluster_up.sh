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

if pgrep -fl fisco-bcos >/dev/null 2>&1; then
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
echo ">> enabling Web3 RPC ([web3_rpc] enable=true) on all nodes"
for cfg in "$OUTDIR"/127.0.0.1/node*/config.ini; do
  [ -f "$cfg" ] && perl -p -i -e 'if (/\[web3_rpc\]/){$f=1} elsif ($f && s/enable\s*=\s*false/enable=true/i){$f=0}' "$cfg"
done

START="$OUTDIR/127.0.0.1/start_all.sh"
[ -f "$START" ] || { echo "ERROR: expected $START after generation, not found" >&2; exit 1; }
echo ">> starting nodes"
bash "$START"

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
