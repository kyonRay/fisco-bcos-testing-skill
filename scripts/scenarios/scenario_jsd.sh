#!/usr/bin/env bash
# scenario_jsd.sh — "jsd" gate scenario family: drive real parallel transaction load through the
# chain with java-sdk-demo's DMC transfer demos, and check the chain's own balance-conservation
# assertion afterwards.
#
# Why this exists alongside dual_rpc: dual_rpc sends a handful of transactions to prove both RPC
# surfaces agree. This one sends hundreds concurrently across a DAG-shaped, a self-transfer, and a
# star-shaped access pattern, with DAG execution both ON and OFF, then relies on each demo's own
# end-of-run check that the sum of all balances still equals what it should. That check is a real
# state oracle: a parallel-execution bug that double-spends or drops a transfer breaks the sum even
# when every individual receipt says success.
#
# Mirrors tools/.ci/java_sdk_demo_ci_test.sh's check_all_dmc_transfer (same three classes, same
# argument shape), so the gate and CI exercise the same paths.
#
# Requires (real run):
#   JSD_DIR            path to a BUILT java-sdk-demo distribution — the directory holding
#                      apps/ conf/ lib/ (i.e. the repo's dist/ after `bash gradlew ass`). No
#                      default is shipped: this scenario refuses to invent a pass when the
#                      distribution is absent, the same way scenario_malformed refuses without
#                      TAMPER_HELPER. Build it anywhere with a JDK 8/11 and copy dist/ over — it is
#                      pure Java, so it does not have to be built on the machine under test.
#   java               on PATH (JDK 8+), or JAVA_BIN pointed at a specific java binary.
#   a live chain       already brought up and funded by apply_profile.sh (the account this
#                      scenario signs with is the genesis auth_admin, which apply_profile funds).
#
# Env:
#   SCENARIO_DRY=1     print the planned runs and return 0 without touching the chain. The only
#                      path exercised by this repo's tests.
#   RG_CLUSTER_DIR     cluster output dir (default ./nodes-release-gate, matching gate.sh)
#   JSD_GROUP          group id (default group0)
#   JSD_COUNT          per-run transaction count (default 50, as in the CI script)
#   JSD_QPS            per-run send rate (default 10, as in the CI script)
#   BCOS_RPC_URL       BCOS RPC endpoint the demos connect to (default http://127.0.0.1:20200)
#   JAVA_BIN           java binary to invoke (default: java, resolved via PATH) — an installed
#                      libexec layout may not have java on PATH under the account the gate runs
#                      as, so this lets the caller point at a specific binary.

SCENARIO_JSD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The three access shapes CI runs, each with DAG execution on and off. The middle field is the
# demo's own "user count" argument and differs per class in the CI script — kept identical here.
JSD_RUNS=(
    "DMCTransferDag:4"
    "DMCTransferMyself:3"
    "DMCTransferStar:5"
)

# ---------------------------------------------------------------------------
# Pure function — no IO. Unit-tested by tests/scenario_jsd_test.sh.
# ---------------------------------------------------------------------------

# _jsd_verdict <exit_code> <output> — return 0 only when the run both exited cleanly AND printed
# its balance-conservation result. Exit code alone is not enough: the demos exit 0 after printing
# per-transaction errors, so a run that lost transactions can still look clean from $?. The
# punctuation around the marker differs per class ("expectBalance!", "expectBalance !"), so match
# the stable phrase, not the whole line.
_jsd_verdict() {
    local rc="$1"
    local out="$2"
    [[ "$rc" == "0" ]] || return 1
    [[ "$out" == *"total balance equal expectBalance"* ]] || return 1
    # "Errors: 3" — any non-zero error tally fails the run even when the balance line is present.
    [[ "$out" =~ Errors:[[:space:]]*[1-9] ]] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# IO helpers — live-chain-only.
# ---------------------------------------------------------------------------

# _jsd_wire <jsd_dir> <cluster_dir> — point the demo distribution at the cluster under test:
# SSL off (every gate profile disables RPC SSL), a single peer, and the genesis auth_admin account
# pinned. Pinning matters for the same reason it did for the console: the SDK's default is "a
# randomly generated account", which nobody funded, so every deploy comes back "Not enough cash".
_jsd_wire() {
    local jsd_dir="$1"
    local cluster_dir="$2"
    local node_dir="$cluster_dir/127.0.0.1"
    local accounts_dir="$cluster_dir/ca/accounts"
    local port gov pem

    [[ -f "$jsd_dir/conf/config-example.toml" ]] || {
        echo "ERROR: scenario_jsd: $jsd_dir/conf/config-example.toml missing — JSD_DIR must point at a built java-sdk-demo dist/ (apps/ conf/ lib/)" >&2
        return 1
    }
    [[ -d "$accounts_dir" ]] || {
        echo "ERROR: scenario_jsd: $accounts_dir not found — expected the cluster apply_profile.sh created (override with RG_CLUSTER_DIR)" >&2
        return 1
    }

    for pem in "$accounts_dir"/*.pem; do
        [[ -f "$pem" ]] || continue
        [[ "$pem" == *.pub.pem || "$pem" == *.public.pem ]] && continue
        gov="$(basename "$pem" .pem)"
        [[ "$gov" =~ ^0x[0-9a-fA-F]{40}$ ]] && break
        gov=""
    done
    [[ -n "$gov" ]] || { echo "ERROR: scenario_jsd: no 0x<40hex>.pem account in $accounts_dir" >&2; return 1; }

    port="${BCOS_RPC_URL:-http://127.0.0.1:20200}"
    port="${port##*:}"

    cp "$jsd_dir/conf/config-example.toml" "$jsd_dir/conf/config.toml"
    [[ -d "$node_dir/sdk" ]] && cp -r "$node_dir/sdk"/* "$jsd_dir/conf/" 2>/dev/null
    mkdir -p "$jsd_dir/account/ecdsa"
    cp -r "$accounts_dir"/* "$jsd_dir/account/ecdsa/"

    PORT="$port" ADDR="$gov" perl -0pi -e '
        s{disableSsl\s*=\s*"false"}{disableSsl = "true"};
        s{^peers\s*=.*$}{peers=["127.0.0.1:$ENV{PORT}"]}m;
        s{^[#[:space:]]*accountAddress\s*=.*$}{accountAddress = "$ENV{ADDR}"}m;
    ' "$jsd_dir/conf/config.toml"

    echo ">> scenario_jsd: wired $jsd_dir -> 127.0.0.1:$port, SSL off, signing as $gov" >&2
}

# _jsd_dry — print the planned runs without touching the chain.
_jsd_dry() {
    local entry cls users dag
    for entry in "${JSD_RUNS[@]}"; do
        cls="${entry%%:*}"
        users="${entry##*:}"
        for dag in true false; do
            echo "DRY: scenario_jsd: ${JAVA_BIN:-java} -cp 'conf/:lib/*:apps/*' org.fisco.bcos.sdk.demo.perf.$cls ${JSD_GROUP:-group0} $users ${JSD_COUNT:-50} ${JSD_QPS:-10} $dag"
        done
    done
    echo "DRY: scenario_jsd: each run verified via _jsd_verdict (exit 0 + 'total balance equal expectBalance' + no non-zero Errors tally)"
}

# scenario_jsd_run [outdir] — wire the demo distribution at the live cluster, run every
# class x DAG-mode combination, and fail if any of them fails its verdict.
scenario_jsd_run() {
    local outdir="${1:-.}"

    if [[ "${SCENARIO_DRY:-0}" == 1 ]]; then
        _jsd_dry
        return 0
    fi

    local jsd_dir="${JSD_DIR:-}"
    if [[ -z "$jsd_dir" || ! -d "$jsd_dir/apps" ]]; then
        echo "ERROR: scenario_jsd: JSD_DIR is not set to a built java-sdk-demo distribution (need <dir>/apps, <dir>/conf, <dir>/lib)." >&2
        echo "       Build it with a JDK 8/11 — 'git clone https://github.com/FISCO-BCOS/java-sdk-demo && bash gradlew ass' — and copy its dist/ here." >&2
        echo "       Refusing to report a pass for load coverage that never ran." >&2
        return 1
    fi
    command -v "${JAVA_BIN:-java}" >/dev/null 2>&1 || { echo "ERROR: scenario_jsd: ${JAVA_BIN:-java} not on PATH (set JAVA_BIN to a specific binary)" >&2; return 1; }

    _jsd_wire "$jsd_dir" "${RG_CLUSTER_DIR:-./nodes-release-gate}" || return 1

    local log="$outdir/jsd.log"
    local entry cls users dag out rc failed=0
    for entry in "${JSD_RUNS[@]}"; do
        cls="${entry%%:*}"
        users="${entry##*:}"
        for dag in true false; do
            echo ">> scenario_jsd: $cls users=$users count=${JSD_COUNT:-50} qps=${JSD_QPS:-10} dag=$dag" | tee -a "$log" >&2
            rc=0
            out="$(cd "$jsd_dir" && "${JAVA_BIN:-java}" -cp "conf/:lib/*:apps/*" \
                "org.fisco.bcos.sdk.demo.perf.$cls" \
                "${JSD_GROUP:-group0}" "$users" "${JSD_COUNT:-50}" "${JSD_QPS:-10}" "$dag" 2>&1)" || rc=$?
            echo "$out" >> "$log"
            if _jsd_verdict "$rc" "$out"; then
                echo "OK: scenario_jsd: $cls dag=$dag (balance conserved)" | tee -a "$log" >&2
            else
                echo "FAIL: scenario_jsd: $cls dag=$dag exited $rc without a clean balance check — see $log" | tee -a "$log" >&2
                printf '%s\n' "$out" | tail -15 | sed 's/^/         /' >&2
                failed=1
            fi
        done
    done
    return $failed
}

# Register into gate.sh's GATE_SCENARIOS map, guarded the same way the sibling scenario files are:
# when this file is sourced standalone (by tests/scenario_jsd_test.sh) gate.sh's
# `declare -A GATE_SCENARIOS=()` has not run, and a bare assignment would trip `set -u`.
declare -gA GATE_SCENARIOS 2>/dev/null || true
GATE_SCENARIOS[jsd]=scenario_jsd_run
