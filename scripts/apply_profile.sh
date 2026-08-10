#!/usr/bin/env bash
# apply_profile.sh — replay a captured production .profile onto a local FISCO-BCOS AIR cluster.
#
# Usage:
#   apply_profile.sh -p <profile> [-o outdir] [--dry-run] [-h]
#     -p  path to a .profile file (required)          e.g. profiles/production-enterprise.profile
#     -o  output dir for the generated cluster         (default ./nodes-release-gate)
#     --dry-run  print the plan to stdout and exit — no build_chain, no cluster_up.sh, no network.
#                Prints: (1) the build_chain invocation incl. compatibility_version, (2) the
#                config.ini patch lines from [config_ini_override], (3) one setSystemConfigByKey
#                line per [system_config_replay] pair. Flags absent from the profile are never
#                invented or emitted.
#     -h  print this help and exit
#
#   Host-provided env vars (not part of any .profile file):
#     FISCO_BIN   specific fisco-bcos binary for cluster_up.sh -e (default: cluster_up.sh's own)
#     WEB3_BASE   Web3 RPC base port for cluster_up.sh -w; OUTRANKS the profile's own captured
#                 web3_rpc.listen_port in the later config.ini patch too (default: 8545)
#
# Real-run (no --dry-run; needs a live fisco-bcos binary — NOT exercised by this skill's own
# tests, since there is no binary in this environment):
#   1. cluster_up.sh (sibling fisco-bcos-testing skill) runs build_chain + start_all with this
#      profile's compatibility_version + cluster topology (-v/-n/-p/-s, plus -e/-w from the env
#      vars above), and waits for RPC to answer.
#   2. Each node's config.ini is patched per [config_ini_override] (web3_rpc.listen_port keeps
#      whatever WEB3_BASE-derived port step 1 already set; every other listen_port key gets the
#      profile's own base+i renumbering).
#   3. The cluster is restarted so the config.ini patch takes effect.
#   4. Each [system_config_replay] pair is replayed via the Java console's setSystemConfigByKey.
set -euo pipefail

# Requires bash 4+ (profile_lib.sh uses associative arrays). Fail clearly instead of a cryptic
# `declare: -gA: invalid option` on stock macOS bash 3.2.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "apply_profile.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE_PATH=""
OUTDIR="./nodes-release-gate"
DRY_RUN=0

# Pull the long --dry-run flag out before getopts sees the rest (getopts only knows short opts).
args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

while getopts "p:o:h" opt; do
    case "$opt" in
        p) PROFILE_PATH="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bad flag; -h for help" >&2; exit 2 ;;
    esac
done

[[ -z "$PROFILE_PATH" ]] && { echo "ERROR: -p <profile> is required. -h for help." >&2; exit 2; }
[[ -f "$PROFILE_PATH" ]] || { echo "ERROR: profile not found: $PROFILE_PATH" >&2; exit 1; }

# _apply_profile_cluster_up_args <outdir> <version> <fisco_bin> <node_count> <ports> <web3_base>
# <sm_mode> — fills global APPLY_CU_ARGS with the cluster_up.sh argv (Task 3's cluster_up.sh
# -v/-w passthrough) needed to bring up this profile's topology. Empty fisco_bin/web3_base omit
# -e/-w so cluster_up.sh falls back to its own defaults (repo-root binary / port 8545); sm_mode
# "1" adds the bare -s flag.
#
# `return 0` is required, not decorative — the same trap Task 3's own
# _cluster_up_build_chain_argv hit: if this function's LAST executed statement were the trailing
# `[[ "$sm_mode" == "1" ]] && ...` and sm_mode were "0" (the common non-SM case), that conditional
# evaluates false and the function itself returns 1 under set -euo pipefail — aborting the whole
# script at its bare top-level call site below.
_apply_profile_cluster_up_args() {
    local outdir="$1" version="$2" fisco_bin="$3" node_count="$4" ports="$5" web3_base="$6" sm_mode="$7"
    APPLY_CU_ARGS=(-o "$outdir" -v "$version" -n "$node_count" -p "$ports")
    [[ -n "$fisco_bin" ]] && APPLY_CU_ARGS+=(-e "$fisco_bin")
    [[ -n "$web3_base" ]] && APPLY_CU_ARGS+=(-w "$web3_base")
    [[ "$sm_mode" == "1" ]] && APPLY_CU_ARGS+=(-s)
    return 0
}

# _apply_profile_web3_port <profile_listen_port> <node_index> <web3_base_override> — the
# web3_rpc.listen_port value to write into node<node_index>'s config.ini. A host-provided
# web3_base_override (from $WEB3_BASE) OUTRANKS the profile's own captured port: without this, the
# config.ini patch loop's later pass over [config_ini_override] would blindly rewrite the port
# cluster_up.sh already brought the cluster up on (base+i, per WEB3_BASE) back to the profile's own
# captured base+i — silently undoing the override. Empty override falls back to the profile's own
# port.
_apply_profile_web3_port() {
    local profile_port="$1" node_idx="$2" override="$3" base="$1"
    [[ -n "$override" ]] && base="$override"
    echo $((base + node_idx))
}

source "$SCRIPT_DIR/profile_lib.sh"
profile_load "$PROFILE_PATH"

genesis_compat="${PROFILE_GENESIS[compatibility_version]:-}"
[[ -z "$genesis_compat" ]] && { echo "ERROR: profile has no [genesis] compatibility_version" >&2; exit 1; }

# Cluster topology for the cluster_up.sh call below (both dry-run and real-run paths share it, so
# the dry-run plan text matches what a real run would actually do). node_count comes from the
# profile's own [meta] node_count (e.g. rpbft-scale.profile's 7), default 4 — matching
# cluster_up.sh's own default. sm_mode comes from the profile's [genesis] sm_crypto. FISCO_BIN and
# WEB3_BASE are host-provided env vars (not part of any profile file): FISCO_BIN selects a specific
# fisco-bcos binary, WEB3_BASE overrides the Web3 RPC base port cluster_up.sh brings the cluster up
# on (and, via _apply_profile_web3_port below, the port the later config.ini patch loop keeps).
node_count="${PROFILE_META[node_count]:-4}"
sm_mode=0
[[ "${PROFILE_GENESIS[sm_crypto]:-}" == "true" ]] && sm_mode=1
cu_ports="30300,20200"
_apply_profile_cluster_up_args "$OUTDIR" "$genesis_compat" "${FISCO_BIN:-}" "$node_count" "$cu_ports" "${WEB3_BASE:-}" "$sm_mode"

if [[ "$DRY_RUN" == 1 ]]; then
    echo "== apply_profile dry-run =="
    echo "profile: $PROFILE_PATH"
    echo "outdir:  $OUTDIR"
    echo ""
    echo "[1/3] cluster_up.sh (wraps build_chain.sh + start_all.sh):"
    echo "  cluster_up.sh ${APPLY_CU_ARGS[*]}   # compatibility_version $genesis_compat"
    echo ""
    echo "[2/3] config.ini patch (from [config_ini_override]):"
    while read -r pair; do
        [[ -z "$pair" ]] && continue
        fullkey="${pair%% *}"
        value="${pair#* }"
        if [[ "$fullkey" == *listen_port && "$value" =~ ^[0-9]+$ ]]; then
            echo "  ${fullkey} = ${value}+i   # per-node: node<i> gets $value+i (see the patch loop)"
        else
            echo "  ${fullkey} = ${value}"
        fi
    done < <(profile_config_pairs)
    echo ""
    echo "[3/3] console replay (from [system_config_replay]):"
    while read -r pair; do
        [[ -z "$pair" ]] && continue
        key="${pair%% *}"
        value="${pair#* }"
        echo "  setSystemConfigByKey ${key} ${value}"
    done < <(profile_replay_pairs)
    exit 0
fi

# ---------------------------------------------------------------------------
# Real-run — needs live chain. Never reached from --dry-run.
# ---------------------------------------------------------------------------

# CLUSTER_UP is overridable via env for testing (a spy/recorder script stands in for the real
# cluster_up.sh so a test can assert the real call's argv without a live chain).
CLUSTER_UP="${CLUSTER_UP:-$SCRIPT_DIR/../../fisco-bcos-testing/scripts/cluster_up.sh}"
[[ -f "$CLUSTER_UP" ]] || {
    echo "ERROR: sibling skill script not found: $CLUSTER_UP (expected the fisco-bcos-testing skill checked out alongside this one)" >&2
    exit 1
}

echo ">> [1/4] cluster_up (needs live chain): build_chain + start_all into $OUTDIR"
# Threads this profile's compatibility_version + cluster topology into cluster_up.sh (Task 3's
# -v/-n/-p/-w/-s/-e), via the SAME APPLY_CU_ARGS array the dry-run plan above already printed —
# the "GAP: no compatibility_version passthrough" limitation this comment used to describe here is
# now closed.
bash "$CLUSTER_UP" "${APPLY_CU_ARGS[@]}"
NODE_DIR="$OUTDIR/127.0.0.1"

echo ">> [2/4] patching config.ini per profile (needs live chain)"
while read -r pair; do
    [[ -z "$pair" ]] && continue
    fullkey="${pair%% *}"
    value="${pair#* }"
    section="${fullkey%%.*}"
    key="${fullkey#*.}"
    for cfg in "$NODE_DIR"/node*/config.ini; do
        [[ -f "$cfg" ]] || continue
        # A captured production profile legitimately holds ONE listen_port per service, because
        # production runs one node per host. Writing that single port into all 4 local nodes makes
        # every node but the first die with "acceptor bind failed" — and since only node0 is
        # probed for readiness, the cluster then looks healthy while consensus can never reach
        # quorum. Renumber port values base+index, the convention build_chain already uses for the
        # p2p and rpc ports.
        node_value="$value"
        if [[ "$key" == *listen_port && "$value" =~ ^[0-9]+$ ]]; then
            node_idx="$(basename "$(dirname "$cfg")")"
            node_idx="${node_idx#node}"
            if [[ "$section" == "web3_rpc" && "$key" == "listen_port" ]]; then
                # WEB3_BASE (if the host set it) outranks the profile's own captured port here —
                # cluster_up.sh above already brought this cluster up on WEB3_BASE+i (Task 3's -w),
                # so blindly applying the profile's base+i would silently undo that override.
                node_value="$(_apply_profile_web3_port "$value" "$node_idx" "${WEB3_BASE:-}")"
            else
                node_value=$((value + node_idx))
            fi
        fi
        # Pass section/key/value via env instead of interpolating them into the perl source
        # text (a value containing '/', '$', '@', or a quote would otherwise corrupt the
        # source or prematurely close the s/// delimiter). {} delimiters sidestep the '/'
        # that can legitimately appear in a config value (e.g. a path).
        # A substitution that matches nothing is the quiet killer here: the key gets silently
        # skipped, the node keeps its generated default, and the run still claims to reproduce
        # production. Make perl exit 9 when it changed nothing so a profile naming a key this
        # build does not emit fails loudly instead.
        patch_rc=0
        SECTION="$section" KEY="$key" VALUE="$node_value" perl -0pi -e '
            $n += s{(\[\Q$ENV{SECTION}\E\][^\[]*?\n\s*\Q$ENV{KEY}\E\s*=\s*)\S+}{$1$ENV{VALUE}}s;
            END { exit($n ? 0 : 9) }
        ' "$cfg" || patch_rc=$?
        if [[ "$patch_rc" == 9 ]]; then
            echo "ERROR: apply_profile: [$section] $key not found in $cfg — nothing was patched, so the profile is NOT applied." >&2
            echo "       The profile names a config key this build does not emit (check the [$section] block in the generated config.ini and NodeConfig.cpp for the current key name)." >&2
            exit 1
        elif [[ "$patch_rc" != 0 ]]; then
            echo "ERROR: apply_profile: patching [$section] $key in $cfg failed (perl exit $patch_rc)" >&2
            exit 1
        fi
    done
done < <(profile_config_pairs)

echo ">> [3/4] restarting cluster to pick up config.ini patch (needs live chain)"
bash "$NODE_DIR/stop_all.sh"
bash "$NODE_DIR/start_all.sh"

# _fund_console_account — give the account the console signs with a balance, so that every
# transaction issued after tx_gas_price goes non-zero can actually pay for its gas. Mirrors
# tools/.ci/java_sdk_demo_ci_test.sh's own sequence (feature_balance -> feature_balance_precompiled
# -> addBalance, lines 134/232-241): build_chain writes the genesis auth-admin account — which is
# also the registered balanceGovernor, and addBalance accepts no one else — into
# <outdir>/ca/accounts/, and the console picks its signing account up from account/ecdsa/.
# Called from the replay loop the moment feature_balance_precompiled is enabled, which the
# profile's own key order guarantees is before tx_gas_price is set.
_fund_console_account() {
    local accounts_dir="$OUTDIR/ca/accounts"
    # tools/.ci/java_sdk_demo_ci_test.sh funds 1e10, but that CI chain never sets tx_gas_price, so
    # gas is free there. Under the production profile (tx_gas_price 21000) a single 500000-gas
    # deploy costs 1.05e10 — just over CI's figure, and the transaction is rejected with
    # {"code":-32603,"message":"InsufficientFunds"}. Fund with headroom instead of the CI number.
    local amount="${RG_FUND_AMOUNT:-1000000000000000000}"
    local gov pem out rc=0

    [[ -d "$accounts_dir" ]] || {
        echo "ERROR: apply_profile: $accounts_dir not found — cannot fund the console account, and every later transaction would fail with 'Not enough cash' once tx_gas_price is non-zero." >&2
        return 1
    }

    # The governor address is the pem's own filename, so take it from disk rather than parsing
    # console output: `listAccount` prints "0x..(current account) <=", address BEFORE the label,
    # and the console's default account is a freshly RANDOM one (see config.toml [account]
    # accountAddress: "Default is a randomly generated account") — which is not the governor and
    # therefore cannot call addBalance at all.
    for pem in "$accounts_dir"/*.pem; do
        [[ -f "$pem" ]] || continue
        [[ "$pem" == *.pub.pem || "$pem" == *.public.pem ]] && continue
        gov="$(basename "$pem" .pem)"
        [[ "$gov" =~ ^0x[0-9a-fA-F]{40}$ ]] && break
        gov=""
    done
    [[ -n "$gov" ]] || {
        echo "ERROR: apply_profile: no 0x<40hex>.pem account found in $accounts_dir" >&2
        return 1
    }

    mkdir -p account/ecdsa
    cp -r "$accounts_dir"/* account/ecdsa/
    # Pin the console to that account. Without this the console signs as its own random account and
    # addBalance is rejected — only the registered balanceGovernor (the genesis auth_admin account,
    # which is this pem) may call it.
    ADDR="$gov" perl -0pi -e 's{^[#[:space:]]*accountAddress\s*=.*$}{accountAddress = "$ENV{ADDR}"}m' conf/config.toml
    echo "  pinned console accountAddress = $gov (genesis auth_admin / balanceGovernor)"

    # Confirm the console actually adopted it before spending a transaction on the assumption.
    out="$(bash console.sh listAccount 2>&1)" || rc=$?
    if [[ "$rc" != 0 ]] || ! grep -q "${gov}(current account)" <<<"$out"; then
        echo "ERROR: apply_profile: console did not adopt $gov as its current account; listAccount said:" >&2
        sed 's/^/         /' <<<"$out" >&2
        return 1
    fi

    # The governor first (it signs everything the replay itself sends), then every extra account the
    # caller says its scenarios will spend from. RG_FUND_ADDRESSES is explicit on purpose: the Web3
    # leg signs with its own key, and an unfunded account there surfaces as
    # {"code":-32603,"message":"InsufficientFunds"} from eth_sendRawTransaction. Listing the
    # addresses beats probing the chain to guess whether balance accounting is on.
    local target
    for target in "$gov" ${RG_FUND_ADDRESSES:-}; do
        target="${target//,/}"
        [[ -n "$target" ]] || continue
        echo "  addBalance $target $amount"
        rc=0
        out="$(bash console.sh addBalance "$target" "$amount" 2>&1)" || rc=$?
        if [[ "$rc" != 0 ]] || ! grep -qE '"code"[[:space:]]*:[[:space:]]*0|[Ss]uccess' <<<"$out"; then
            echo "ERROR: apply_profile: addBalance $target $amount did not report success — transactions from that account will fail for lack of gas money." >&2
            sed 's/^/         /' <<<"$out" >&2
            return 1
        fi
    done
}

echo ">> [4/4] replaying setSystemConfigByKey via console (needs live chain)"
# The console exits 0 even when it never reached the chain (it prints "Failed to create BcosSDK"
# and returns success), so `set -e` alone does NOT catch a failed replay. Without an explicit
# check, a run where all 14 production flags silently failed to apply still reports "cluster
# ready" — the gate then tests a DEFAULT-config chain while claiming production fidelity, which
# is the one false-green this whole script exists to prevent. Demand the success envelope.
while read -r pair; do
    [[ -z "$pair" ]] && continue
    key="${pair%% *}"
    value="${pair#* }"
    echo "  setSystemConfigByKey $key $value"
    # The console parses setSystemConfigByKey values as Java integers and dies client-side on a
    # 0x-prefixed string (`For input string: "x5208"`) — the call never reaches the chain. The
    # chain's own validator demands the opposite: SystemConfigPrecompiled.cpp:162-168 rejects a
    # value that is not a hex string, with the message "must be a hex number like 0xa". Send the
    # decimal equivalent so the replay can proceed. FIDELITY CAVEAT: the chain stores the string it
    # is given, so the local chain ends up holding "21000" where the captured production chain
    # holds "0x5208" — eth_gasPrice reports the same number either way, but the stored
    # representation is NOT identical to production. Say so rather than hide it.
    console_value="$value"
    if [[ "$value" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
        console_value=$((value))
        echo "  NOTE: $key sent as decimal $console_value (console cannot parse $value); stored representation will differ from the captured profile"
    fi
    replay_rc=0
    replay_out="$(bash console.sh setSystemConfigByKey "$key" "$console_value" 2>&1)" || replay_rc=$?
    if [[ "$replay_rc" != 0 ]] || ! grep -qE '"code"[[:space:]]*:[[:space:]]*0' <<<"$replay_out"; then
        echo "ERROR: apply_profile: setSystemConfigByKey $key $value did not report success — the profile is NOT applied, refusing to report this cluster as production-faithful." >&2
        echo "       console said:" >&2
        sed 's/^/         /' <<<"$replay_out" >&2
        exit 1
    fi
    # Fund immediately after the balance precompiled goes live: from here on the chain charges gas
    # to a real balance, and the profile's key order puts tx_gas_price later (see the ordering note
    # in the profile's [system_config_replay] section).
    if [[ "$key" == "feature_balance_precompiled" && "$value" != "0" ]]; then
        _fund_console_account || exit 1
    fi
done < <(profile_replay_pairs)

echo ">> cluster ready at $OUTDIR (profile: $PROFILE_PATH)"
