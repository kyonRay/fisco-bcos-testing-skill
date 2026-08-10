#!/usr/bin/env bash
# Boundary + spy tests for cluster_up.sh's _cluster_up_build_chain_argv array builder.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"

# ---- Part 1: pure-function boundary test (extracts and evals just the function body) ----
eval "$(sed -n '/^_cluster_up_build_chain_argv()/,/^}/p' "$SD/../../fisco-bcos-testing/scripts/cluster_up.sh")"
_cluster_up_build_chain_argv 4 "30300,20200" "/tmp/o u t" "/bin/f i" "" "3.0.0" ""
printf '%s\n' "${BUILD_CHAIN_ARGV[@]}" | grep -Fxq "/tmp/o u t" && ok=1 || ok=0
assert_eq "1" "$ok" "spaced outdir kept as ONE argv element"
printf '%s\n' "${BUILD_CHAIN_ARGV[@]}" | grep -Fxq "/bin/f i" && ok=1 || ok=0
assert_eq "1" "$ok" "spaced binary kept as ONE element"
assert_contains " ${BUILD_CHAIN_ARGV[*]} " " -v 3.0.0 " "version present"
_cluster_up_build_chain_argv 4 "30300,20200" /tmp/o "" "-s" "" ""
assert_not_contains " ${BUILD_CHAIN_ARGV[*]} " " -v " "no version -> no -v"
assert_not_contains " ${BUILD_CHAIN_ARGV[*]} " " -e " "no binary -> no -e"
assert_contains " ${BUILD_CHAIN_ARGV[*]} " " -s " "SM flag present"

# ---- Part 2: real-code-path spy test ----
# Drives the ACTUAL cluster_up.sh (not just the extracted function) through a fake repo root
# containing a spy build_chain.sh that logs argv and fabricates just enough output (a node0/
# config.ini with a [web3_rpc] block, a no-op start_all.sh) for cluster_up.sh's own Web3-enable
# renumbering + readiness probe to run for real. start_all/readiness are stubbed (-n 0 makes the
# post-start_all "N nodes running" check pass trivially with 0 expected/0 observed; a fake `curl`
# on PATH answers the readiness probe instantly) so no fisco-bcos node process ever starts.
CU="$SD/../../fisco-bcos-testing/scripts/cluster_up.sh"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/tools/BcosAirBuilder" "$WORK/bin" "$WORK/stubbin"

# Spy build_chain.sh: logs "$@" (one element per line) to $LOGFILE (inherited from the caller's
# env, not hardcoded — lets the two invocations below use separate log files), then fabricates a
# single node0/config.ini + start_all.sh under whatever -o dir it was given.
cat > "$WORK/tools/BcosAirBuilder/build_chain.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$LOGFILE"
OUTDIR=""
while getopts "p:l:o:e:v:sd" opt; do
  case "$opt" in
    o) OUTDIR="$OPTARG" ;;
    *) : ;;
  esac
done
[ -n "$OUTDIR" ] || { echo "fake build_chain: no -o given" >&2; exit 1; }
mkdir -p "$OUTDIR/127.0.0.1/node0"
cat > "$OUTDIR/127.0.0.1/node0/config.ini" <<CFG
[web3_rpc]
    enable=false
    listen_port=8545
CFG
cat > "$OUTDIR/127.0.0.1/start_all.sh" <<'ST'
#!/usr/bin/env bash
exit 0
ST
chmod +x "$OUTDIR/127.0.0.1/start_all.sh"
exit 0
FAKE
chmod +x "$WORK/tools/BcosAirBuilder/build_chain.sh"

# Fake fisco-bcos binary for the non-download (-e) path.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/fisco-bcos"
chmod +x "$WORK/bin/fisco-bcos"

# Fake curl: answers the readiness probe instantly, no real network/node needed.
cat > "$WORK/stubbin/curl" <<'CURLSTUB'
#!/usr/bin/env bash
echo '{"jsonrpc":"2.0","id":1,"result":"0x1"}'
CURLSTUB
chmod +x "$WORK/stubbin/curl"

LOGFILE1="$WORK/log1.log"; : > "$LOGFILE1"
LOGFILE2="$WORK/log2.log"; : > "$LOGFILE2"
OUT1="$WORK/o u t"          # space-containing outdir, download path, custom -w
OUT2="$WORK/out2"           # non-download path (-e)

# cluster_up.sh's own node-count check does `pgrep -f "$NODE_ROOT/node" | wc -l | tr -d ' '` under
# pipefail: pgrep exits 1 when it matches nothing, which aborts the whole script before it reaches
# its "N of M nodes running" diagnostic — a pre-existing landmine unrelated to this task's scope.
# Sidestep it (rather than silently accepting a non-zero exit) by giving pgrep something real to
# match: one dummy background process per run whose faked argv0 contains "$NODE_ROOT/node".
DUMMY_PIDS=()
spawn_dummy_node() {
  local node_root="$1/127.0.0.1"
  mkdir -p "$node_root"
  bash -c 'exec -a "$1/node0/dummy" sleep 30' _ "$node_root" &
  DUMMY_PIDS+=("$!")
}
kill_dummies() { for p in "${DUMMY_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap 'kill_dummies; cleanup' EXIT
spawn_dummy_node "$OUT1"
spawn_dummy_node "$OUT2"

set +e
( cd "$WORK" && PATH="$WORK/stubbin:$PATH" LOGFILE="$LOGFILE1" \
    bash "$CU" -d -n 0 -p "30300,20200" -o "$OUT1" -w 18545 ) >"$WORK/run1.out" 2>&1
rc1=$?
( cd "$WORK" && PATH="$WORK/stubbin:$PATH" LOGFILE="$LOGFILE2" \
    bash "$CU" -n 0 -p "30300,20200" -o "$OUT2" -e "$WORK/bin/fisco-bcos" ) >"$WORK/run2.out" 2>&1
rc2=$?
set -e
kill_dummies

assert_eq "0" "$rc1" "spy: download-path cluster_up.sh run exits 0 (see $WORK/run1.out on fail)"
assert_eq "0" "$rc2" "spy: non-download-path cluster_up.sh run exits 0 (see $WORK/run2.out on fail)"

# (a) real call routes through the array with a SPACE-containing outdir preserved as ONE argument
grep -Fxq "$OUT1" "$LOGFILE1" && ok=1 || ok=0
assert_eq "1" "$ok" "spy(a): spaced outdir reaches real build_chain invocation as one argv element"

# (b) both download and non-download paths route through the builder: download omits -e,
# non-download includes it with the exact binary path as its own argv element.
grep -Fxq -- "-e" "$LOGFILE1" && ok=1 || ok=0
assert_eq "0" "$ok" "spy(b): download path omits -e"
grep -Fxq -- "-e" "$LOGFILE2" && ok=1 || ok=0
assert_eq "1" "$ok" "spy(b): non-download path includes -e"
grep -Fxq "$WORK/bin/fisco-bcos" "$LOGFILE2" && ok=1 || ok=0
assert_eq "1" "$ok" "spy(b): non-download -e value reaches build_chain as one argv element"

# (c) non-default -w 18545 lands as listen_port=18545 in node0's generated config.ini (base+0)
grep -q 'listen_port=18545' "$OUT1/127.0.0.1/node0/config.ini" && ok=1 || ok=0
assert_eq "1" "$ok" "spy(c): -w 18545 -> node0 config.ini listen_port=18545 (base+0)"

assert_done
