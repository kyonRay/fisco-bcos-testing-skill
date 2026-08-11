#!/usr/bin/env bash
# scenario_upgrade.sh — "upgrade" gate scenario family (production-enterprise profile only):
# replay the release doc's T0-T8 version-upgrade timeline (operation_and_maintenance/upgrade.md,
# see the sibling fisco-bcos-testing skill's references/version-upgrade.md for the mechanism this
# encodes) against a locally-reproduced copy of that profile:
#   T0  reproduce prod            FISCO_BIN=<old_bin> apply_profile.sh -p <profile_path> — the
#                                  baseline is built from the OLD binary, not this build-dir's own
#                                  default, and profile_path defaults to production-enterprise but
#                                  is caller-overridable (5th arg to scenario_upgrade_run)
#   T1  baseline gate             one-shot crash/liveness/stateroot oracle pass + snapshot each
#                                  target-version flag's PRE-bump value (expected "null")
#   T2-T4 rolling binary swap     stop one node -> atomically swap the shared binary (same-dir
#                                  temp + mv, never a bare cp onto the live target) -> restart ->
#                                  sample height+hash from 3 nodes -> _upg_no_fork -> repeat per node
#   T5  bump data version         console setSystemConfigByKey compatibility_version <target_ver>
#   T6  flag-flip assertion       re-read each target-version flag, _upg_flag_flipped(before,after)
#   T7  re-run gate               one-shot oracle pass again, must stay consistent with T1
#   T8  optional rollback         only if UPGRADE_ROLLBACK=1: swap binaries back + restore the
#                                  profile's original genesis compatibility_version
#
# This file is SOURCED (by gate.sh's `for f in "$SCRIPT_DIR"/scenarios/*.sh; do source "$f";
# done` loop — see scripts/gate.sh — or standalone by tests/scenario_upgrade_test.sh /
# tests/upgrade_swap_test.sh), so it must not `set -e`/`set -u` at file scope: that would change
# the sourcing script's own shell options. Registration at the bottom is guarded for the same
# reason. Matches scenario_ut.sh / scenario_dual_rpc.sh / scenario_malformed.sh's convention
# exactly.
#
# Design: _upg_no_fork, _upg_flag_flipped, and _upg_t0_apply_argv are pure functions (no IO) —
# tested directly in tests/scenario_upgrade_test.sh (the first two) and
# tests/upgrade_swap_test.sh (the third, alongside the real-IO swap helpers below).
# _upg_target_flags is a file-read-only helper (parses the real FISCO-BCOS Features.cpp shipped in
# this checkout — no network, no running chain) that is ALSO hermetically testable and IS
# exercised by tests/scenario_upgrade_test.sh, per the "facts don't get baked in" editing
# invariant: the set of bugfix flags a given target version activates is a per-release fact and
# must be re-derived from source, never hardcoded here. _upg_atomic_replace_binary and
# _upg_swap_node_binary do real file/process IO (mktemp/cp/mv, stop.sh/start.sh) but against a
# throwaway tmpdir fixture rather than a live chain, so tests/upgrade_swap_test.sh exercises them
# for real too — see that file. scenario_upgrade_run itself is live-chain-only IO (apply_profile.sh
# + console + curl + oracle_*.sh) and is NOT exercised by tests, other than its SCENARIO_DRY=1
# branch (prints the T0-T8 plan, sends nothing).
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

# _UPG_DEFAULT_PROFILE_ABS — the production-enterprise profile's absolute path, resolved relative
# to this script's own dir (not $PWD), so scenario_upgrade_run's 5th (profile_path) argument has a
# sane default without needing a caller-provided path. Plain concatenation on top of the already-
# canonicalized SCENARIO_UPG_DIR (no extra `cd`/`pwd` subshell) so this assignment can never fail
# under a caller's `set -e` even if the profiles dir happened to be missing.
_UPG_DEFAULT_PROFILE_ABS="$SCENARIO_UPG_DIR/../../profiles/production-enterprise.profile"

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

# _upg_t0_apply_argv <old_bin> <profile_path> <outdir> — fill global UPG_T0_ARGV with the argv T0
# passes to apply_profile.sh (-p/-o are the only flags that script accepts), and FISCO_BIN_FOR_T0
# with the binary T0's baseline must be built with. old_bin is deliberately threaded via the env
# var (apply_profile.sh reads FISCO_BIN — see that script's own header doc), NOT embedded in argv:
# there is no -e/--bin flag on apply_profile.sh to put a binary path into, and folding it into
# argv would silently drop it the moment apply_profile.sh's own getopts saw an unrecognized flag.
_upg_t0_apply_argv() {
    UPG_T0_ARGV=(-p "$2" -o "$3")
    FISCO_BIN_FOR_T0="$1"
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
# next `.to = protocol::BlockVersion::` entry, or end of table if it's the last one.
#
# Return code is the caller's ONLY way to tell "this version legitimately introduces zero new
# flags" (exit 0, empty stdout) apart from "flag derivation is broken" (exit 1, empty stdout) —
# both used to print nothing, which let a broken derivation slip past T6 as a vacuous pass (a
# false-green a review caught). So:
#   - target_ver not shaped like x.y.z                                -> ERROR, exit 1
#   - features_cpp missing                                             -> ERROR, exit 1
#   - target_ver's token has NO `.to = protocol::BlockVersion::` entry
#     in the table at all (unknown version, or the table was
#     restructured upstream and this grep/awk no longer matches it)    -> ERROR, exit 1
#   - target_ver's entry EXISTS but its own .flags = {} is empty       -> exit 0, empty stdout
#     (a genuinely flag-less release — legitimate, not an error)
_upg_target_flags() {
    local target_ver="$1"
    local features_cpp="$2"

    # MINOR: reject a malformed target_ver up front. Without this, e.g. "3.17" (missing the
    # patch component) builds tok="V3_17_VERSION", which can never match the real
    # "V3_17_0_VERSION" table entry and would otherwise only surface via the generic
    # not-found-in-table error below — still correct after that fix, but this gives a clearer,
    # earlier diagnostic for the actual mistake (wrong version string, not a missing table entry).
    if [[ ! "$target_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: scenario_upgrade: target_ver '$target_ver' is not a x.y.z version string" >&2
        return 1
    fi

    local tok="V${target_ver//./_}_VERSION"
    [[ -f "$features_cpp" ]] || {
        echo "ERROR: scenario_upgrade: Features.cpp not found at $features_cpp" >&2
        return 1
    }

    # IMPORTANT: distinguish "not in the table at all" from "in the table with zero flags" BEFORE
    # running the extraction awk — grep -F (fixed string, no regex metachar surprises from tok)
    # against the literal "BlockVersion::<tok>," pattern every upgradeRoadmap entry uses.
    if ! grep -qF "BlockVersion::${tok}," "$features_cpp"; then
        echo "ERROR: scenario_upgrade: target version $target_ver (token $tok) has NO entry in $features_cpp's upgradeRoadmap table — flag derivation cannot proceed (unknown/malformed target_ver, or the table was restructured upstream and this script's parser is stale)" >&2
        return 1
    fi

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
    local key="$1" out val
    # Read through listSystemConfigs, NOT getSystemConfigByKey. Two live-run reasons:
    #   1. A bugfix flag that has never been set has no entry, and getSystemConfigByKey answers
    #      {"code":3008,"msg":"Entry: bugfix_auth_check does not exists!"} instead of a value —
    #      but the pre-bump snapshot is exactly the case T6 needs to read.
    #   2. listSystemConfigs prints one table row per key, "| bugfix_auth_check | null | 0 |",
    #      which covers set and unset alike.
    # The previous `tail -n1` also could not have worked either way: the console closes its output
    # with "}" and a blank line, so every flag read back as "}" and T6 compared "}" to "}" — the
    # same trailing-line trap scenario_dual_rpc's get() fell into.
    out="$(_upg_console listSystemConfigs 2>/dev/null)"
    val="$(printf '%s' "$out" | awk -F'|' -v k="$key" '
        {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            if ($2 == k) { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit }
        }')"
    printf '%s' "$val" | tr -d '[:space:]'
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

# _upg_run_oracle_triad <phase-label> <rpc_url> <node_dir> <pid...> — one bounded pass of all
# three release-gate oracles (crash / liveness / stateroot), matching gate.sh's own
# run_oracles_once exactly — T1/T7 are "baseline gate" and "re-run gate" checkpoints, not
# crash-only spot checks. node_dir feeds _run_stateroot_oracle's multi-node discovery
# (_discover_stateroot_urls), the same shared runner gate.sh/run_case.sh/fuzz_bcos.sh use.
_upg_run_oracle_triad() {
    local phase="$1" rpc_url="$2" node_dir="$3"
    shift 3
    local trc=0 height
    bash "$SCENARIO_UPG_DIR/../oracle_crash.sh" --once "$@" || trc=1
    bash "$SCENARIO_UPG_DIR/../oracle_liveness.sh" -r "$rpc_url" || trc=1
    height="$(_upg_rpc_current_height "$rpc_url")"
    if [[ -z "$height" ]]; then
        echo "ERROR: scenario_upgrade: could not read block height from $rpc_url for stateroot oracle ($phase)" >&2
        trc=1
    else
        local sr_rc=0
        _run_stateroot_oracle "$height" "$node_dir" "" || sr_rc=$?
        if [[ "$sr_rc" == 3 ]]; then
            echo "ERROR: scenario_upgrade: stateroot ($phase): <2 node RPCs discovered under $node_dir" >&2
            trc=1
        elif [[ "$sr_rc" == 1 ]]; then
            echo "FAIL: scenario_upgrade: stateroot divergence (fork) detected during $phase @ height $height" >&2
            trc=1
        fi
    fi
    return $trc
}

# _upg_atomic_replace_binary <src> <root> — pure file-swap primitive, no stop/start. Copies <src>
# into a temp file in the SAME directory as the target (<root>, not e.g. $TMPDIR) so the final
# `mv` is an atomic same-filesystem rename rather than a cross-filesystem copy a reader could catch
# mid-write, sets it to mode 0755, then mv -f's it onto <root>/fisco-bcos. Deliberately does NOT
# touch a running node's process (see header GAP note) — _upg_swap_node_binary below wraps this
# with the stop/start semantics an actual rolling upgrade needs.
#
# `chmod 755`, not `chmod +x`: mktemp deliberately creates its file 0600, and `+x` only ADDS the
# execute bits, landing on 0711 — so every rolling swap silently stripped the group/other READ
# bits a build_chain-generated fisco-bcos ships with (0755). Nothing fails loudly, because exec
# needs only the x bit, but the deployed binary's mode drifts on each upgrade and any non-owner
# reader of it (checksum verification, backup, debugger) starts getting EACCES. Observed live:
# 0755 -> 0711 after one node3 swap.
_upg_atomic_replace_binary() {
    local src="$1" root="$2" tmp
    tmp="$(mktemp "$root/.fisco-bcos.XXXXXX")"
    cp "$src" "$tmp"
    chmod 755 "$tmp"
    mv -f "$tmp" "$root/fisco-bcos"
}

# _upg_swap_node_binary <node_dir_root> <node_name> <bin> — stop the node, atomically overwrite
# the shared binary via _upg_atomic_replace_binary, restart it (see header GAP note on why this is
# a genuine per-node swap despite the binary file being shared across all nodes on this
# single-machine AIR layout). Previously did a bare `cp` straight onto the live target path — that
# risked a start.sh racing the write and exec'ing a partially-copied binary (or, on some
# filesystems, ETXTBSY against the still-running process this same loop is about to restart);
# _upg_atomic_replace_binary's same-dir-temp-then-rename closes that.
_upg_swap_node_binary() {
    local root="$1" node_name="$2" bin="$3"
    echo ">> scenario_upgrade: [$node_name] stop -> swap binary -> start ($bin)" >&2
    bash "$root/$node_name/stop.sh"
    _upg_atomic_replace_binary "$bin" "$root"
    bash "$root/$node_name/start.sh"
}

# _upg_dry — print the T0-T8 plan without sending anything. This is the only branch of this
# scenario exercised outside a live chain. Still resolves the real target-version flag list via
# _upg_target_flags (file-read-only, no network) so the printed T6 step is not a placeholder.
_upg_dry() {
    local old_bin="$1" new_bin="$2" target_ver="$3" profile_path="$4"
    local repo_root features_cpp flags_str="(repo root not found — cannot resolve)"
    if repo_root="$(_upg_find_repo_root)"; then
        features_cpp="$repo_root/bcos-framework/bcos-framework/ledger/Features.cpp"
        # Capture via plain command substitution (NOT a pipe) so $? below is
        # _upg_target_flags's own exit status, not tr's — see the IMPORTANT-finding fix in
        # scenario_upgrade_run's real-run path for why this distinction matters: "not in the
        # table" (error) and "in the table with zero flags" (benign) must not both read as "none".
        local flags_output flags_rc
        flags_output="$(_upg_target_flags "$target_ver" "$features_cpp" 2>&1)"
        flags_rc=$?
        if [[ $flags_rc -ne 0 ]]; then
            flags_str="UNRESOLVED — $flags_output"
        elif [[ -z "$flags_output" ]]; then
            flags_str="(confirmed: $target_ver is in the table, zero new flags)"
        else
            flags_str="$(printf '%s' "$flags_output" | tr '\n' ' ')"
        fi
    fi
    echo "DRY: scenario_upgrade: T0 reproduce prod: FISCO_BIN=$old_bin apply_profile.sh -p $profile_path -o <outdir>"
    echo "DRY: scenario_upgrade: T1 baseline gate: one-shot crash/liveness/stateroot oracle pass; snapshot pre-bump value of each target flag"
    echo "DRY: scenario_upgrade: T2-T4 rolling binary swap: per node, stop -> swap $old_bin -> $new_bin -> start -> sample 3 nodes' height+hash -> _upg_no_fork"
    echo "DRY: scenario_upgrade: T5 bump data version: console setSystemConfigByKey compatibility_version $target_ver"
    echo "DRY: scenario_upgrade: T6 flag-flip assertion: for each of [$flags_str], _upg_flag_flipped(before,after)"
    echo "DRY: scenario_upgrade: T7 re-run gate: one-shot oracle pass again, compare against T1"
    echo "DRY: scenario_upgrade: T8 optional rollback (UPGRADE_ROLLBACK=1 only): swap binaries back to $old_bin, restore original compatibility_version"
}

# scenario_upgrade_run <outdir> <old_bin> <new_bin> <target_ver> [profile_path] — execute the
# T0-T8 timeline above. profile_path is an ABSOLUTE path (default: _UPG_DEFAULT_PROFILE_ABS, the
# production-enterprise profile); a host CLI resolving a logical profile NAME rather than a path
# should do so via ${FBT_PROFILE_DIR:-<script_dir>/../../profiles}/<name>.profile before calling
# in here, since this function itself only ever consumes an already-resolved path. Live-chain-only:
# needs a fisco-bcos checkout with a completed build (both binaries), a running BCOS RPC cluster
# reproduced by T0 FROM old_bin (not this build-dir's own default binary — see _upg_t0_apply_argv),
# and console.sh. Returns 1 if any non-optional T-step fails; T8 is skipped (not failed) unless
# UPGRADE_ROLLBACK=1.
scenario_upgrade_run() {
    local outdir="${1:-.}"
    local old_bin="${2:-}"
    local new_bin="${3:-}"
    local target_ver="${4:-}"
    local profile_path="${5:-$_UPG_DEFAULT_PROFILE_ABS}"

    if [[ "${SCENARIO_DRY:-0}" == 1 ]]; then
        _upg_dry "${old_bin:-<old_bin>}" "${new_bin:-<new_bin>}" "${target_ver:-<target_ver>}" "$profile_path"
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
    [[ -f "$profile_path" ]] || {
        echo "ERROR: scenario_upgrade: profile not found: $profile_path" >&2
        return 1
    }

    local repo_root
    repo_root="$(_upg_find_repo_root)" || {
        echo "ERROR: scenario_upgrade: not inside a FISCO-BCOS checkout (no tools/BcosAirBuilder/build_chain.sh found above $SCENARIO_UPG_DIR)" >&2
        return 1
    }
    local features_cpp="$repo_root/bcos-framework/bcos-framework/ledger/Features.cpp"
    # IMPORTANT fix: capture via plain command substitution, NOT `mapfile < <(...)`. Process
    # substitution decouples the producer's exit status from the reading command — `mapfile`
    # itself returns 0 even when _upg_target_flags failed loudly (e.g. target_ver has no entry in
    # the upgradeRoadmap table at all), so the old `mapfile ... || return 1` never actually fired
    # on that failure: it silently fell through to "0 flags found" and let T6 vacuously pass. A
    # plain `"$(...)"` command substitution's $? IS _upg_target_flags's own exit status.
    local flags_output flags_rc
    flags_output="$(_upg_target_flags "$target_ver" "$features_cpp")"
    flags_rc=$?
    if [[ $flags_rc -ne 0 ]]; then
        echo "ERROR: scenario_upgrade: flag derivation failed for target version $target_ver (see ERROR above) — refusing to run T6 against an unverifiable flag set" >&2
        return 1
    fi
    local -a flags=()
    if [[ -n "$flags_output" ]]; then
        mapfile -t flags <<<"$flags_output"
    fi
    if [[ ${#flags[@]} -eq 0 ]]; then
        echo "NOTE: scenario_upgrade: target version $target_ver is confirmed present in $features_cpp's upgradeRoadmap table but activates no new bugfix/feature flags — T6 will have nothing to assert (this is a benign confirmed case, not a derivation failure)"
    fi

    # Do NOT create $outdir here. T0's build_chain refuses to generate into a directory that
    # already exists ("[FATAL] <dir> DIR already exist, please check!"), so pre-creating it for the
    # step logs made this scenario fail at its very first step, every time — it killed itself on
    # its own log directory. apply_profile.sh/build_chain create the directory; anything that wants
    # to log into it does so after T0 returns.
    local node_dir_root="$outdir/127.0.0.1"
    local rc=0

    echo "-- scenario_upgrade: T0 reproduce prod (old_bin=$old_bin, profile=$profile_path)"
    # T0's baseline MUST be built from old_bin, not this build-dir's own default fisco-bcos binary
    # — otherwise T2-T4's "swap old -> new" never actually starts from the old version, and the
    # whole rolling-upgrade timeline this scenario exists to exercise tests nothing. old_bin is
    # threaded via the FISCO_BIN env var (apply_profile.sh reads it, see that script's own header
    # doc), not argv — _upg_t0_apply_argv fills UPG_T0_ARGV with only -p/-o.
    _upg_t0_apply_argv "$old_bin" "$profile_path" "$outdir"
    FISCO_BIN="$FISCO_BIN_FOR_T0" bash "$SCENARIO_UPG_DIR/../apply_profile.sh" "${UPG_T0_ARGV[@]}" || {
        echo "FAIL: scenario_upgrade: T0 apply_profile.sh failed" >&2
        return 1
    }
    mkdir -p "$outdir"

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

    # RPC_URL: derive from node0's FINAL config.ini via _primary_web3_url, not from the profile's
    # own [config_ini_override] value — see gate.sh's/run_case.sh's own comment on this (Design
    # Decision rev3 #2 fix: a raw PROFILE_CONFIG read misses a host WEB3_BASE override applied by
    # apply_profile.sh). This is the whole-cluster gate-oracle endpoint used by T1/T7 below; it is
    # distinct from the per-node BCOS RPC ports (_upg_rpc_url_for) the T2-T4 no-fork check samples
    # individually.
    source "$SCENARIO_UPG_DIR/../profile_lib.sh"
    # Sourced here, not at file scope — same convention scenario_dual_rpc.sh's own
    # SCENARIO_DRPC_ORACLE_LIB source uses (see its comment): only reached on a real run, never by
    # SCENARIO_DRY=1 or by merely sourcing this file.
    source "$SCENARIO_UPG_DIR/../oracle_lib.sh"
    # profile_load is still needed here: PROFILE_GENESIS[compatibility_version] is read later
    # (see the comment at that use site) and this is the only profile_load call in this function.
    profile_load "$profile_path"
    local rpc_url
    rpc_url="$(_primary_web3_url "$node_dir_root")" || {
        echo "ERROR: scenario_upgrade: could not derive the primary Web3 RPC URL from $node_dir_root/node0/config.ini" >&2
        return 1
    }

    local -a pids=()
    mapfile -t pids < <(_upg_discover_pids)
    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "ERROR: scenario_upgrade: could not discover any live fisco-bcos node PIDs under $node_dir_root — T0's apply_profile.sh may not have brought up a chain. Real-run requires a live chain; refusing to continue with no crash-oracle PIDs." >&2
        return 1
    fi

    echo "-- scenario_upgrade: T1 baseline gate"
    local t1_rc=0
    # CRITICAL fix: a T1 failure must independently fail the whole scenario (rc=1) here, not
    # merely be recorded into t1_rc for the T7-vs-T1 comparison below. Previously t1_rc only ever
    # influenced the outcome via `[[ "$t1_rc" == 0 && "$t7_rc" != 0 ]]` — which is FALSE whenever
    # T1 itself already failed, so that branch's `else` printed "OK: T7 consistent with T1" and rc
    # stayed 0 even with a live crash/consensus-halt/state-mismatch present at (or caused by) the
    # very start of the upgrade. That is exactly the false-green this scenario exists to catch.
    if ! _upg_run_oracle_triad "T1-baseline" "$rpc_url" "$node_dir_root" "${pids[@]}"; then
        echo "FAIL: scenario_upgrade: T1 baseline gate failed (chain unhealthy before/at the start of the upgrade)" >&2
        rc=1
        t1_rc=1
    fi
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
    # The console exits 0 even when the chain refused the call, so checking $? alone let T5 report
    # success having changed nothing: against the production profile (auth_check_status=1) the chain
    # answers {"code":-50000,"msg":"Permission denied"} — "Maybe you should use 'setSysConfigProposal'"
    # — because committee governance is on. T6 then compared unset flags against unset flags and T7
    # found itself "consistent with T1", producing a complete, plausible upgrade run in which no
    # upgrade happened. Demand the success envelope, and say which governance path is needed.
    #
    # Two paths, because the profile decides which one the chain accepts. Without governance the
    # direct call works; with auth_check_status=1 it is refused and the bump must be a committee
    # proposal. Try direct first, fall back on "Permission denied" — that keeps the non-governance
    # profiles on the simpler path and needs no per-profile configuration.
    local t5_out t5_rc=0
    t5_out="$(_upg_console setSystemConfigByKey compatibility_version "$target_ver" 2>&1)" || t5_rc=$?
    if [[ "$t5_rc" == 0 ]] && grep -qE '"code"[[:space:]]*:[[:space:]]*0' <<<"$t5_out"; then
        echo "OK: scenario_upgrade: T5 bumped compatibility_version to $target_ver (direct)"
    elif grep -q "Permission denied" <<<"$t5_out"; then
        echo ">> scenario_upgrade: T5 direct set refused (governance on) — retrying as a committee proposal"
        t5_rc=0
        t5_out="$(_upg_console setSysConfigProposal compatibility_version "$target_ver" 2>&1)" || t5_rc=$?
        # A single governor at 0% thresholds makes the proposal execute immediately, so success is
        # "Proposal Status : finished" — NOT a {"code":0} envelope, which this command never prints.
        # The console then tries to refresh its cached group info and may print
        # "Switch to group group0 failed"; that is after the fact and must not be read as failure.
        if [[ "$t5_rc" != 0 ]] || ! grep -q "Proposal Status *: *finished" <<<"$t5_out"; then
            echo "FAIL: scenario_upgrade: T5 committee proposal for compatibility_version=$target_ver did not finish — the chain was NOT upgraded, so T6/T7 below assert nothing." >&2
            sed 's/^/         /' <<<"$t5_out" >&2
            grep -q "please check valid range" <<<"$t5_out" && \
                echo "       This is java-sdk 3.8.0's AuthManager rejecting the version string (its EnumNodeVersion stops at 3.7.0). Build java-sdk from branch release-3.9.0 and put its jar plus its jackson 2.20 dependencies in the console's lib/." >&2
            rc=1
        else
            echo "OK: scenario_upgrade: T5 bumped compatibility_version to $target_ver (committee proposal)"
        fi
    else
        echo "FAIL: scenario_upgrade: T5 compatibility_version bump to $target_ver did not report success — the chain was NOT upgraded, so T6/T7 below assert nothing." >&2
        sed 's/^/         /' <<<"$t5_out" >&2
        rc=1
    fi

    echo "-- scenario_upgrade: T6 flag-flip assertion"
    # NOT `${!flags[@]+"${!flags[@]}"}`: combining the `!` index expansion with the `+`
    # set-or-empty test makes bash parse the whole thing as an INDIRECT expansion — it takes the
    # value of flags[@] and treats it as a variable name, so a live T6 died with
    # `bugfix_auth_check bugfix_v1_error_handling ...: invalid variable name`. Guard on the element
    # count instead, which is unambiguous and works the same on every bash 4+.
    local i after
    for ((i = 0; i < ${#flags[@]}; i++)); do
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
        _upg_run_oracle_triad "T7-rerun" "$rpc_url" "$node_dir_root" "${pids[@]}" || t7_rc=1
    fi
    # This is an ADDITIONAL signal on top of T1's own independent pass/fail check above (T1
    # failing already set rc=1 there, regardless of what T7 does) — it specifically catches a
    # regression the upgrade itself introduced (T1 was healthy, T7 is not).
    if [[ "$t1_rc" == 0 && "$t7_rc" != 0 ]]; then
        echo "FAIL: scenario_upgrade: T7 regressed vs T1 baseline (T1 passed, T7 failed)" >&2
        rc=1
    elif [[ "$t1_rc" != 0 ]]; then
        echo "NOTE: scenario_upgrade: T7=$t7_rc — T1 already failed above, which alone already fails this scenario"
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
