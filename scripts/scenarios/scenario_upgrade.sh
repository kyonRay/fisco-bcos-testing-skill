#!/usr/bin/env bash
# scenario_upgrade.sh — "upgrade" gate scenario family (production-enterprise profile only):
# replay the release doc's T0-T8 version-upgrade timeline (operation_and_maintenance/upgrade.md,
# see the sibling fisco-bcos-testing skill's references/version-upgrade.md for the mechanism this
# encodes) against a locally-reproduced copy of that profile:
#   T0  reproduce prod            apply_profile.sh -p production-enterprise.profile
#   T1  baseline gate             one-shot crash/liveness/stateroot oracle pass + snapshot each
#                                  target-version flag's PRE-bump value (expected "null")
#   T2-T4 rolling binary swap     stop one node -> swap shared binary -> restart -> sample
#                                  height+hash from 3 nodes -> _upg_no_fork -> repeat per node
#   T5  bump data version         console setSystemConfigByKey compatibility_version <target_ver>
#   T6  flag-flip assertion       re-read each target-version flag, _upg_flag_flipped(before,after)
#   T7  re-run gate               one-shot oracle pass again, must stay consistent with T1
#   T8  optional rollback         only if UPGRADE_ROLLBACK=1: swap binaries back + restore the
#                                  profile's original genesis compatibility_version
#
# This file is SOURCED (by gate.sh's `for f in "$SCRIPT_DIR"/scenarios/*.sh; do source "$f";
# done` loop — see scripts/gate.sh — or standalone by tests/scenario_upgrade_test.sh), so it must
# not `set -e`/`set -u` at file scope: that would change the sourcing script's own shell options.
# Registration at the bottom is guarded for the same reason. Matches scenario_ut.sh /
# scenario_dual_rpc.sh / scenario_malformed.sh's convention exactly.
#
# Design: _upg_no_fork and _upg_flag_flipped are pure functions (no IO) — the two decision
# points this scenario exists to exercise, and the ONLY part of this file unit-tested by
# tests/scenario_upgrade_test.sh. _upg_target_flags is a file-read-only helper (parses the real
# FISCO-BCOS Features.cpp shipped in this checkout — no network, no running chain) that is ALSO
# hermetically testable and IS exercised by tests/scenario_upgrade_test.sh, per the "facts don't
# get baked in" editing invariant: the set of bugfix flags a given target version activates is a
# per-release fact and must be re-derived from source, never hardcoded here. scenario_upgrade_run
# itself is live-chain-only IO (apply_profile.sh + console + curl + oracle_*.sh) and is NOT
# exercised by tests, other than its SCENARIO_DRY=1 branch (prints the T0-T8 plan, sends nothing).
#
# Flag-derivation source of truth: this deliberately greps
# bcos-framework/bcos-framework/ledger/Features.cpp's setUpgradeFeatures() upgradeRoadmap table
# (`{.to = protocol::BlockVersion::V3_17_0_VERSION, .flags = {...}}`), NOT Features.h's enum
# comments. Features.h annotates only one flag (bugfix_auth_check) with an explicit "activate at
# V3_17_0" marker in its comment; the other six flags that 3.17.0 actually activates
# (bugfix_v1_error_handling, bugfix_gas_payment_balance_precheck, bugfix_precompiled_feature_gate,
# bugfix_evm_storage_status, bugfix_statestorage_hash_v3_17, bugfix_nonce_ordering) have no such
# per-flag comment marker — grepping Features.h for "V3_17" would silently under-report the flag
# set. Features.cpp's upgradeRoadmap table is the actual code the node runs to decide which flags
# a version bump activates, so it is both more complete and more authoritative.
#
# GAP (documented assumption, verified only against a live chain — same honesty standard as
# scenario_malformed.sh / scenario_dual_rpc.sh's own GAP notes):
#   - build_chain.sh copies ONE shared binary to `<node_dir_root>/fisco-bcos`
#     (`cp "${binary_path}" "${node_dir}/../"`), and each node's generated start.sh execs
#     `${SHELL_FOLDER}/../fisco-bcos`. On Unix, overwriting that file's content does not affect an
#     already-running process's in-memory executable image — only processes started (or
#     restarted) AFTER the overwrite pick up the new bytes. A "rolling per-node binary swap" on
#     this single-machine AIR layout therefore means: overwrite the one shared file, then
#     stop+restart ONLY the node under test — its siblings, still running their original process
#     image, genuinely continue on the old binary until their own turn. This is real Unix
#     semantics, not a simulated approximation, but it has not been exercised against a live
#     chain by this task.
#   - Node RPC ports follow build_chain's `-p 30300,20200` convention: node<i>'s BCOS RPC listens
#     on 20200+i. Not independently re-verified here (same caveat scenario_dual_rpc.sh gives for
#     its own JsonRpcInterface.h param-order assumptions).
#   - getBlockNumber/getBlockByNumber JSON-RPC result shapes (plain-string height, `"hash"` field
#     on the block object) are a best-effort assumption parsed with sed, not independently
#     verified against a live response — same honesty standard as scenario_dual_rpc.sh's own
#     stateRoot field parsing.
#   - console getSystemConfigByKey's output for an unset flag is assumed to end in a literal
#     "null" line, matching version-upgrade.md's documented listSystemConfigs convention
#     ("Value = null (or 0) means off").
#
# Env:
#   SCENARIO_DRY=1     print the T0-T8 plan (including the live-derived target-version flag list)
#                      and return 0 without executing anything. This is the only path exercised
#                      by this repo's own tests — there is no live chain in this environment.
#   NODE_DIR           cluster node-dir root (default matches gate.sh's own
#                      CLUSTER_OUTDIR="./nodes-release-gate" layout: <outdir>/127.0.0.1).
#   BCOS_RPC_BASE_PORT base BCOS RPC port; node<i> is assumed to listen on BASE+i (default 20200).
#   BCOS_GROUP_ID      group id for the <groupID, nodeName, ...> JSON-RPC param convention
#                      (default "group0").
#   CONSOLE_DIR        console.sh working directory (default console/dist).
#   UPGRADE_ROLLBACK   1 to also run the optional T8 rollback step (default 0: T8 is skipped, not
#                      failed).

SCENARIO_UPG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pure functions — no IO. The core of what tests/scenario_upgrade_test.sh exercises.
# ---------------------------------------------------------------------------

# _upg_no_fork "<h> <hash>" "<h> <hash>" "<h> <hash>" — three "height hash" observations, one per
# node. Return 0 when no pair of them reports the SAME height with a DIFFERENT hash (agreement, or
# simply different heights — a node still catching up is not by itself a fork); return 1 the
# moment any same-height pair disagrees on hash.
_upg_no_fork() {
    local -a items=("$1" "$2" "$3")
    local i j hi hj hashi hashj
    for ((i = 0; i < 3; i++)); do
        for ((j = i + 1; j < 3; j++)); do
            hi="${items[i]%% *}"
            hashi="${items[i]#* }"
            hj="${items[j]%% *}"
            hashj="${items[j]#* }"
            if [[ "$hi" == "$hj" && "$hashi" != "$hashj" ]]; then
                return 1
            fi
        done
    done
    return 0
}

# _upg_flag_flipped <before> <after> — return 0 iff the flag was off before (before == "null" or
# empty) AND on after (after == "1"); return 1 for every other combination, including "was already
# on before" (not this scenario's job to re-assert) and "still null after" (the exact false-green
# this scenario exists to catch: a version bump that silently failed to activate its own flags).
_upg_flag_flipped() {
    local before="$1" after="$2"
    [[ ("$before" == "null" || -z "$before") && "$after" == "1" ]]
}

# ---------------------------------------------------------------------------
# File-read-only helper — no network, no running chain, but real IO against this checkout's own
# source tree. Hermetically testable (the source file is always present in this environment) and
# exercised by tests/scenario_upgrade_test.sh, per the header's "facts don't get baked in" note.
# ---------------------------------------------------------------------------

# _upg_find_repo_root — walk up from this script's own dir (not $PWD) looking for the same repo
# marker scenario_ut.sh's own scenario_ut_find_repo_root uses, so this is cwd-independent too.
_upg_find_repo_root() {
    local d="$SCENARIO_UPG_DIR"
    while [[ "$d" != "/" ]]; do
        [[ -f "$d/tools/BcosAirBuilder/build_chain.sh" ]] && {
            echo "$d"
            return 0
        }
        d="$(dirname "$d")"
    done
    return 1
}

# _upg_target_flags <target_ver> <features_cpp_path> — print, one per line, the Flag:: names
# Features.cpp's setUpgradeFeatures() activates for <target_ver> (e.g. "3.17.0"), by locating that
# version's `{.to = protocol::BlockVersion::V3_17_0_VERSION, .flags = {...}}` entry in the
# upgradeRoadmap table and extracting every `Flag::<name>` token up to (but not including) the
# next `.to = protocol::BlockVersion::` entry, or end of table if it's the last one. Prints
# nothing (not an error) if <target_ver> has no entry in the table at all — an upgrade to a
# version that introduces no new bugfix/feature flags is a legitimate case, not a failure.
_upg_target_flags() {
    local target_ver="$1"
    local features_cpp="$2"
    local tok="V${target_ver//./_}_VERSION"
    [[ -f "$features_cpp" ]] || {
        echo "ERROR: scenario_upgrade: Features.cpp not found at $features_cpp" >&2
        return 1
    }
    awk -v tok="$tok" '
        /\.to = protocol::BlockVersion::/ {
            if (grabbing) { exit }
            if (index($0, "BlockVersion::" tok) > 0) { grabbing = 1 }
        }
        grabbing { print }
    ' "$features_cpp" | grep -oE 'Flag::[A-Za-z0-9_]+' | sed 's/^Flag:://'
}

# ---------------------------------------------------------------------------
# IO helpers — live-chain-only, never called from SCENARIO_DRY=1 except where noted, and never
# called from this repo's tests.
# ---------------------------------------------------------------------------

_upg_console() {
    local console_dir="${CONSOLE_DIR:-console/dist}"
    (cd "$console_dir" && bash console.sh "$@")
}

# _upg_get_config_value <key> — console getSystemConfigByKey <key>, print the trimmed last
# non-empty line (see header GAP note on console output parsing).
_upg_get_config_value() {
    local key="$1" out
    out="$(_upg_console getSystemConfigByKey "$key" 2>/dev/null)"
    printf '%s' "$out" | tail -n1 | tr -d '[:space:]'
}

# _upg_discover_pids — print live fisco-bcos node PIDs, one per line, discovered via pgrep against
# NODE_DIR. Same convention as scenario_malformed.sh's _mal_discover_pids.
_upg_discover_pids() {
    local node_dir="${NODE_DIR:-./nodes-release-gate/127.0.0.1}"
    pgrep -f "$node_dir/" 2>/dev/null || true
}

# _upg_node_names <node_dir_root> — print each node's dir basename (node0, node1, ...), one per
# line, discovered from the cluster layout build_chain.sh produces.
_upg_node_names() {
    local root="$1" cfg
    for cfg in "$root"/node*/config.ini; do
        [[ -f "$cfg" ]] || continue
        basename "$(dirname "$cfg")"
    done
}

# _upg_rpc_url_for <node_name> — BCOS RPC URL for a node, per the header GAP note's
# base-port-plus-index convention (node3 -> BASE+3).
_upg_rpc_url_for() {
    local node_name="$1" idx base
    idx="${node_name#node}"
    base="${BCOS_RPC_BASE_PORT:-20200}"
    printf 'http://127.0.0.1:%d' "$((base + idx))"
}

# _upg_json_result <json> — pull a bare (possibly unquoted) top-level "result" value out of a
# JSON-RPC response without a jq dependency.
_upg_json_result() {
    printf '%s' "$1" | sed -n 's/.*"result":"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' | head -n1
}

# _upg_height_hash <rpc_url> — print "<height> <hash>" for a node's current chain tip, via
# getBlockNumber then getBlockByNumber (see header GAP note on the assumed result shapes).
_upg_height_hash() {
    local url="$1" resp height resp2 hash
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"getBlockNumber\",\"params\":[\"${BCOS_GROUP_ID:-group0}\",\"\"],\"id\":1}" \
        "$url" 2>/dev/null)"
    height="$(_upg_json_result "$resp")"
    [[ -n "$height" ]] || {
        echo "ERROR: scenario_upgrade: could not read block height from $url" >&2
        return 1
    }
    resp2="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"getBlockByNumber\",\"params\":[\"${BCOS_GROUP_ID:-group0}\",\"\",$height,false],\"id\":1}" \
        "$url" 2>/dev/null)"
    hash="$(printf '%s' "$resp2" | sed -n 's/.*"hash":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    [[ -n "$hash" ]] || {
        echo "ERROR: scenario_upgrade: could not read block hash @ $height from $url" >&2
        return 1
    }
    printf '%s %s' "$height" "$hash"
}

# _upg_rpc_current_height <rpc_url> — print the current Web3 RPC block height as decimal, or
# empty string on failure. Duplicates gate.sh's own private rpc_current_height rather than
# sourcing it, to keep this scenario from depending on that orchestrator's internal
# (non-interface) function name (same reasoning gate.sh gives for ITS OWN duplicate of
# oracle_liveness.sh's rpc_block_number).
_upg_rpc_current_height() {
    local rpc_url="$1" resp hex
    resp="$(curl -sS -m 10 -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$rpc_url" 2>/dev/null)" || { echo ""; return; }
    hex="$(printf '%s' "$resp" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    [[ -z "$hex" ]] && { echo ""; return; }
    printf '%d\n' "$hex"
}

# _upg_run_oracle_triad <phase-label> <rpc_url> <pid...> — one bounded pass of all three
# release-gate oracles (crash / liveness / stateroot), matching gate.sh's own run_oracles_once
# exactly — T1/T7 are "baseline gate" and "re-run gate" checkpoints, not crash-only spot checks.
_upg_run_oracle_triad() {
    local phase="$1" rpc_url="$2"
    shift 2
    local trc=0 height
    bash "$SCENARIO_UPG_DIR/../oracle_crash.sh" --once "$@" || trc=1
    bash "$SCENARIO_UPG_DIR/../oracle_liveness.sh" -r "$rpc_url" || trc=1
    height="$(_upg_rpc_current_height "$rpc_url")"
    if [[ -z "$height" ]]; then
        echo "ERROR: scenario_upgrade: could not read block height from $rpc_url for stateroot oracle ($phase)" >&2
        trc=1
    else
        bash "$SCENARIO_UPG_DIR/../oracle_stateroot.sh" -b "$height" -r "$rpc_url" || trc=1
    fi
    return $trc
}

# _upg_swap_node_binary <node_dir_root> <node_name> <bin> — stop the node, overwrite the shared
# binary, restart it (see header GAP note on why this is a genuine per-node swap despite the
# binary file being shared across all nodes on this single-machine AIR layout).
_upg_swap_node_binary() {
    local root="$1" node_name="$2" bin="$3"
    echo ">> scenario_upgrade: [$node_name] stop -> swap binary -> start ($bin)" >&2
    bash "$root/$node_name/stop.sh"
    cp "$bin" "$root/fisco-bcos"
    bash "$root/$node_name/start.sh"
}

# _upg_dry — print the T0-T8 plan without sending anything. This is the only branch of this
# scenario exercised outside a live chain. Still resolves the real target-version flag list via
# _upg_target_flags (file-read-only, no network) so the printed T6 step is not a placeholder.
_upg_dry() {
    local old_bin="$1" new_bin="$2" target_ver="$3"
    local repo_root features_cpp flags_str="(unresolved)"
    if repo_root="$(_upg_find_repo_root)"; then
        features_cpp="$repo_root/bcos-framework/bcos-framework/ledger/Features.cpp"
        flags_str="$(_upg_target_flags "$target_ver" "$features_cpp" 2>/dev/null | tr '\n' ' ')"
        [[ -n "$flags_str" ]] || flags_str="(none for $target_ver)"
    fi
    echo "DRY: scenario_upgrade: T0 reproduce prod: apply_profile.sh -p profiles/production-enterprise.profile"
    echo "DRY: scenario_upgrade: T1 baseline gate: one-shot crash/liveness/stateroot oracle pass; snapshot pre-bump value of each target flag"
    echo "DRY: scenario_upgrade: T2-T4 rolling binary swap: per node, stop -> swap $old_bin -> $new_bin -> start -> sample 3 nodes' height+hash -> _upg_no_fork"
    echo "DRY: scenario_upgrade: T5 bump data version: console setSystemConfigByKey compatibility_version $target_ver"
    echo "DRY: scenario_upgrade: T6 flag-flip assertion: for each of [$flags_str], _upg_flag_flipped(before,after)"
    echo "DRY: scenario_upgrade: T7 re-run gate: one-shot oracle pass again, compare against T1"
    echo "DRY: scenario_upgrade: T8 optional rollback (UPGRADE_ROLLBACK=1 only): swap binaries back to $old_bin, restore original compatibility_version"
}

# scenario_upgrade_run <outdir> <old_bin> <new_bin> <target_ver> — execute the T0-T8 timeline
# above. Live-chain-only: needs a fisco-bcos checkout with a completed build (both binaries), a
# running BCOS RPC cluster reproduced by T0, and console.sh. Returns 1 if any non-optional T-step
# fails; T8 is skipped (not failed) unless UPGRADE_ROLLBACK=1.
scenario_upgrade_run() {
    local outdir="${1:-.}"
    local old_bin="${2:-}"
    local new_bin="${3:-}"
    local target_ver="${4:-}"

    if [[ "${SCENARIO_DRY:-0}" == 1 ]]; then
        _upg_dry "${old_bin:-<old_bin>}" "${new_bin:-<new_bin>}" "${target_ver:-<target_ver>}"
        return 0
    fi

    [[ -n "$old_bin" && -n "$new_bin" && -n "$target_ver" ]] || {
        echo "ERROR: scenario_upgrade_run requires <outdir> <old_bin> <new_bin> <target_ver>" >&2
        return 1
    }
    [[ -x "$old_bin" ]] || {
        echo "ERROR: scenario_upgrade: old_bin not executable: $old_bin" >&2
        return 1
    }
    [[ -x "$new_bin" ]] || {
        echo "ERROR: scenario_upgrade: new_bin not executable: $new_bin" >&2
        return 1
    }

    local repo_root
    repo_root="$(_upg_find_repo_root)" || {
        echo "ERROR: scenario_upgrade: not inside a FISCO-BCOS checkout (no tools/BcosAirBuilder/build_chain.sh found above $SCENARIO_UPG_DIR)" >&2
        return 1
    }
    local features_cpp="$repo_root/bcos-framework/bcos-framework/ledger/Features.cpp"
    local -a flags=()
    mapfile -t flags < <(_upg_target_flags "$target_ver" "$features_cpp") || return 1
    if [[ ${#flags[@]} -eq 0 ]]; then
        echo "NOTE: scenario_upgrade: target version $target_ver activates no new bugfix/feature flags per $features_cpp — T6 will have nothing to assert"
    fi

    mkdir -p "$outdir"
    local profile="$SCENARIO_UPG_DIR/../../profiles/production-enterprise.profile"
    local node_dir_root="$outdir/127.0.0.1"
    local rc=0

    echo "-- scenario_upgrade: T0 reproduce prod"
    bash "$SCENARIO_UPG_DIR/../apply_profile.sh" -p "$profile" -o "$outdir" || {
        echo "FAIL: scenario_upgrade: T0 apply_profile.sh failed" >&2
        return 1
    }

    local -a node_names=()
    mapfile -t node_names < <(_upg_node_names "$node_dir_root")
    if [[ ${#node_names[@]} -eq 0 ]]; then
        echo "ERROR: scenario_upgrade: no node dirs found under $node_dir_root" >&2
        return 1
    fi
    if [[ ${#node_names[@]} -lt 3 ]]; then
        echo "ERROR: scenario_upgrade: only ${#node_names[@]} node(s) under $node_dir_root — the T2-T4 no-fork check needs at least 3 to be meaningful" >&2
        return 1
    fi

    # RPC_URL: same convention gate.sh's own real-run uses — read straight from the profile's own
    # [config_ini_override] web3_rpc.listen_port (apply_profile.sh patches this into every node's
    # config.ini), falling back to the AIR default of 8545. This is the whole-cluster gate-oracle
    # endpoint used by T1/T7 below; it is distinct from the per-node BCOS RPC ports (_upg_rpc_url_for)
    # the T2-T4 no-fork check samples individually.
    source "$SCENARIO_UPG_DIR/../profile_lib.sh"
    profile_load "$profile"
    local web3_port="${PROFILE_CONFIG[web3_rpc.listen_port]:-8545}"
    local rpc_url="http://127.0.0.1:${web3_port}"

    local -a pids=()
    mapfile -t pids < <(_upg_discover_pids)
    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "ERROR: scenario_upgrade: could not discover any live fisco-bcos node PIDs under $node_dir_root — T0's apply_profile.sh may not have brought up a chain. Real-run requires a live chain; refusing to continue with no crash-oracle PIDs." >&2
        return 1
    fi

    echo "-- scenario_upgrade: T1 baseline gate"
    local t1_rc=0
    _upg_run_oracle_triad "T1-baseline" "$rpc_url" "${pids[@]}" || t1_rc=1
    local flag before_vals=()
    # ${flags[@]+"${flags[@]}"} rather than a bare "${flags[@]}": on bash < 4.4, expanding an
    # array with zero elements under `set -u` (the caller's shell options during a real gate.sh
    # run) raises "unbound variable" even though the array itself IS declared — this idiom (an
    # explicit existence test via `+`) sidesteps that, matching the `set -- "${args[@]+...}"`
    # guard apply_profile.sh/gate.sh already use for the same reason. flags legitimately CAN be
    # empty (a target version that introduces no new bugfix/feature flags — see the NOTE above).
    for flag in ${flags[@]+"${flags[@]}"}; do
        before_vals+=("$(_upg_get_config_value "$flag")")
    done

    echo "-- scenario_upgrade: T2-T4 rolling binary swap (${#node_names[@]} nodes)"
    local name
    for name in "${node_names[@]}"; do
        _upg_swap_node_binary "$node_dir_root" "$name" "$new_bin" || {
            echo "FAIL: scenario_upgrade: T2-T4 swap failed for $name" >&2
            rc=1
            continue
        }
        # Sample height+hash from 3 nodes and feed _upg_no_fork. CRITICAL: an empty/short
        # observation (fewer than 3 nodes answered, or one _upg_height_hash call failed) is an
        # ERROR, not a silent "OK" — a no-fork check that skipped itself would be exactly the
        # false-green this scenario exists to catch (same discipline as scenario_malformed.sh's
        # _mal_verdict: a check that didn't run is never reported as a pass).
        local -a obs=()
        local n ob obs_ok=1
        for n in "${node_names[@]:0:3}"; do
            ob="$(_upg_height_hash "$(_upg_rpc_url_for "$n")")" || obs_ok=0
            [[ -n "$ob" ]] || obs_ok=0
            obs+=("$ob")
        done
        if [[ "$obs_ok" != 1 || ${#obs[@]} -ne 3 ]]; then
            echo "ERROR: scenario_upgrade: could not sample height+hash from 3 nodes after swapping $name (got: ${obs[*]:-<none>}) — no-fork check did NOT run" >&2
            rc=1
        elif ! _upg_no_fork "${obs[0]}" "${obs[1]}" "${obs[2]}"; then
            echo "FAIL: scenario_upgrade: fork detected mid-upgrade after swapping $name: ${obs[*]}" >&2
            rc=1
        else
            echo "OK: scenario_upgrade: no fork after swapping $name"
        fi
    done

    echo "-- scenario_upgrade: T5 bump data version to $target_ver"
    _upg_console setSystemConfigByKey compatibility_version "$target_ver" >/dev/null || {
        echo "FAIL: scenario_upgrade: T5 setSystemConfigByKey compatibility_version failed" >&2
        rc=1
    }

    echo "-- scenario_upgrade: T6 flag-flip assertion"
    local i after
    for i in ${!flags[@]+"${!flags[@]}"}; do
        flag="${flags[$i]}"
        after="$(_upg_get_config_value "$flag")"
        if _upg_flag_flipped "${before_vals[$i]}" "$after"; then
            echo "OK: scenario_upgrade: $flag flipped ${before_vals[$i]} -> $after"
        else
            echo "FAIL: scenario_upgrade: $flag did NOT flip (before=${before_vals[$i]} after=$after)" >&2
            rc=1
        fi
    done

    echo "-- scenario_upgrade: T7 re-run gate, compare against T1"
    mapfile -t pids < <(_upg_discover_pids)
    local t7_rc=0
    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "FAIL: scenario_upgrade: T7 found no live node PIDs at all (all nodes crashed during upgrade?)" >&2
        t7_rc=1
    else
        _upg_run_oracle_triad "T7-rerun" "$rpc_url" "${pids[@]}" || t7_rc=1
    fi
    if [[ "$t1_rc" == 0 && "$t7_rc" != 0 ]]; then
        echo "FAIL: scenario_upgrade: T7 regressed vs T1 baseline (T1 passed, T7 failed)" >&2
        rc=1
    else
        echo "OK: scenario_upgrade: T7 consistent with T1 (T1=$t1_rc T7=$t7_rc)"
    fi

    if [[ "${UPGRADE_ROLLBACK:-0}" == 1 ]]; then
        echo "-- scenario_upgrade: T8 rollback"
        # PROFILE_GENESIS was already populated by the profile_load call above (RPC_URL
        # derivation) — no need to re-source profile_lib.sh or reparse the profile here.
        local orig_compat="${PROFILE_GENESIS[compatibility_version]:-}"
        for name in "${node_names[@]}"; do
            _upg_swap_node_binary "$node_dir_root" "$name" "$old_bin" || rc=1
        done
        if [[ -n "$orig_compat" ]]; then
            _upg_console setSystemConfigByKey compatibility_version "$orig_compat" >/dev/null || rc=1
        fi
    else
        echo "SKIP: scenario_upgrade: T8 rollback (set UPGRADE_ROLLBACK=1 to exercise it)"
    fi

    return $rc
}

# Register into gate.sh's GATE_SCENARIOS map. Guarded: when this file is sourced standalone
# (e.g. by tests/scenario_upgrade_test.sh) rather than via gate.sh, gate.sh's own
# `declare -A GATE_SCENARIOS=()` has not run yet, so under `set -u` a bare assignment into
# GATE_SCENARIOS[upgrade]=... would abort the sourcing script with "unbound variable". Declare it
# (idempotently — declare -A on an already-declared array is a harmless no-op, never resets an
# existing map) before the assignment so standalone sourcing never crashes. Matches
# scenario_ut.sh / scenario_dual_rpc.sh / scenario_malformed.sh's registration guard exactly.
declare -gA GATE_SCENARIOS 2>/dev/null || true
GATE_SCENARIOS[upgrade]=scenario_upgrade_run
