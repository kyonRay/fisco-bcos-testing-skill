#!/usr/bin/env bash
# oracle_lib.sh — pure decision functions for the three release-gate oracles
# (crash / consensus-halt / state-mismatch). Source this file; do not execute
# directly. No IO here — see oracle_crash.sh / oracle_liveness.sh /
# oracle_stateroot.sh for the RPC/process-polling wrappers that feed these.
set -euo pipefail

# Requires bash 4+ (matches profile_lib.sh's guard; this file doesn't use
# associative arrays today, but keeps the same floor as the rest of scripts/
# so a stray macOS bash 3.2 fails clearly instead of a cryptic parse error).
if (( BASH_VERSINFO[0] < 4 )); then
    echo "oracle_lib.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    return 1 2>/dev/null || exit 1
fi

_ORACLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# oracle_liveness_decide <prev_height> <cur_height> <elapsed_s> <has_pending>
# Halt (return 1) when there is pending work, the stall threshold has been
# exceeded, and the height has not advanced. Threshold defaults to 30s,
# overridable via RG_STALL_SEC.
oracle_liveness_decide() {
    local prev="$1" cur="$2" elapsed="$3" has_pending="$4"
    local threshold="${RG_STALL_SEC:-30}"
    if (( has_pending == 1 && elapsed > threshold && cur <= prev )); then
        return 1
    fi
    return 0
}

# oracle_fork_decide <height_a> <hash_a> <height_b> <hash_b>
# Fork (return 1) when two observations report the same height with
# different block hashes.
oracle_fork_decide() {
    local height_a="$1" hash_a="$2" height_b="$3" hash_b="$4"
    if [[ "$height_a" == "$height_b" && "$hash_a" != "$hash_b" ]]; then
        return 1
    fi
    return 0
}

# oracle_stateroot_decide <root...> — variadic. Diverge (return 1) when any
# argument differs from the first.
oracle_stateroot_decide() {
    local first="$1"
    shift
    local root
    for root in "$@"; do
        if [[ "$root" != "$first" ]]; then
            return 1
        fi
    done
    return 0
}

# _discover_stateroot_urls <node_dir> [extra_csv] — one URL per line (deduped,
# sorted) for each node under <node_dir>/node*/config.ini whose [web3_rpc]
# enable=true; appends any URLs from extra_csv (comma-separated). Normalizes
# 0.0.0.0 -> 127.0.0.1, brackets any IPv6 literal (:: -> [::1], bare IPv6 ->
# [addr]). Returns 3 on stderr when fewer than 2 URLs are found.
_discover_stateroot_urls() {
    local node_dir="$1" extra_csv="${2:-}" cfg enabled host port
    local -a urls=()
    # exact-key reader within [web3_rpc]: trim spaces around key, match key == want
    for cfg in "$node_dir"/node*/config.ini; do
        [[ -f "$cfg" ]] || continue
        enabled="$(awk -F= '/^[[:space:]]*\[/{s=($0 ~ /\[web3_rpc\]/)} s{k=$1;gsub(/[[:space:]]/,"",k); if(k=="enable"){v=$2;gsub(/[[:space:]]/,"",v);print v}}' "$cfg" | tail -n1)"
        [[ "$enabled" == "true" ]] || continue
        host="$(awk -F= '/^[[:space:]]*\[/{s=($0 ~ /\[web3_rpc\]/)} s{k=$1;gsub(/[[:space:]]/,"",k); if(k=="listen_ip"){v=$2;gsub(/[[:space:]]/,"",v);print v}}' "$cfg" | tail -n1)"
        port="$(awk -F= '/^[[:space:]]*\[/{s=($0 ~ /\[web3_rpc\]/)} s{k=$1;gsub(/[[:space:]]/,"",k); if(k=="listen_port"){v=$2;gsub(/[[:space:]]/,"",v);print v}}' "$cfg" | tail -n1)"
        [[ -n "$port" ]] || continue
        case "$host" in
            ""|"0.0.0.0") host="127.0.0.1" ;;
            "::"|"[::]")  host="[::1]" ;;   # unspecified IPv6 -> loopback
            \[*\]) ;;                        # already bracketed
            *:*) host="[$host]" ;;          # bare IPv6 literal -> bracket it
        esac
        urls+=("http://$host:$port")
    done
    if [[ -n "$extra_csv" ]]; then local u; local -a e=(); IFS=',' read -r -a e <<< "$extra_csv"
        for u in "${e[@]}"; do [[ -n "$u" ]] && urls+=("$u"); done; fi
    local out n
    out="$(printf '%s\n' "${urls[@]:-}" | awk 'NF' | sort -u)"
    n="$(printf '%s\n' "$out" | awk 'NF' | wc -l | tr -d ' ')"
    [[ "${n:-0}" -ge 2 ]] || { echo "ERROR: _discover_stateroot_urls: found ${n:-0} URL(s) under $node_dir, need >=2" >&2; return 3; }
    printf '%s\n' "$out"
}

# _primary_web3_url <node_dir> — node0's Web3 RPC URL, read from its FINAL config.ini (i.e. after
# apply_profile.sh's config.ini patch loop ran, so a host WEB3_BASE override is already reflected
# there — see _apply_profile_web3_port in apply_profile.sh). Reuses the same exact-key [web3_rpc]
# parse + host-normalization pattern as _discover_stateroot_urls above.
#
# gate.sh and run_case.sh both used to derive their liveness/height RPC_URL straight from the
# PROFILE's own [config_ini_override] web3_rpc.listen_port value — which is only the port
# apply_profile.sh would have written BEFORE any WEB3_BASE override, so a run with WEB3_BASE set
# had every oracle probe the wrong port while the cluster itself was healthy on the right one.
# Deriving RPC_URL from this function instead closes that gap (Design Decision rev3 #2).
#
# If $WEB3_RPC_URL is set (host-injected, e.g. by an outer orchestrator that already knows the
# effective port), it is returned as-is but only after asserting it names the SAME port node0's
# own config.ini says is authoritative — a mismatch is refused rather than silently probing
# whichever of the two is wrong.
#
# rc: 0 on success; 3 when node0's config.ini is missing, its [web3_rpc] is not enabled, or no
# listen_port key is found; 1 when WEB3_RPC_URL is set but disagrees with node0's config.ini.
_primary_web3_url() {
    local node_dir="$1" enabled host port url
    local cfg="$node_dir/node0/config.ini"
    [[ -f "$cfg" ]] || { echo "ERROR: _primary_web3_url: no config.ini at $cfg" >&2; return 3; }
    enabled="$(awk -F= '/^[[:space:]]*\[/{s=($0 ~ /\[web3_rpc\]/)} s{k=$1;gsub(/[[:space:]]/,"",k); if(k=="enable"){v=$2;gsub(/[[:space:]]/,"",v);print v}}' "$cfg" | tail -n1)"
    [[ "$enabled" == "true" ]] || { echo "ERROR: _primary_web3_url: node0's [web3_rpc] is not enabled in $cfg" >&2; return 3; }
    host="$(awk -F= '/^[[:space:]]*\[/{s=($0 ~ /\[web3_rpc\]/)} s{k=$1;gsub(/[[:space:]]/,"",k); if(k=="listen_ip"){v=$2;gsub(/[[:space:]]/,"",v);print v}}' "$cfg" | tail -n1)"
    port="$(awk -F= '/^[[:space:]]*\[/{s=($0 ~ /\[web3_rpc\]/)} s{k=$1;gsub(/[[:space:]]/,"",k); if(k=="listen_port"){v=$2;gsub(/[[:space:]]/,"",v);print v}}' "$cfg" | tail -n1)"
    [[ -n "$port" ]] || { echo "ERROR: _primary_web3_url: no web3_rpc.listen_port found in $cfg" >&2; return 3; }
    case "$host" in
        ""|"0.0.0.0") host="127.0.0.1" ;;
        "::"|"[::]")  host="[::1]" ;;   # unspecified IPv6 -> loopback
        \[*\]) ;;                        # already bracketed
        *:*) host="[$host]" ;;          # bare IPv6 literal -> bracket it
    esac
    url="http://$host:$port"
    if [[ -n "${WEB3_RPC_URL:-}" ]]; then
        if [[ "$WEB3_RPC_URL" != "$url" ]]; then
            echo "ERROR: _primary_web3_url: host-injected WEB3_RPC_URL=$WEB3_RPC_URL does not match node0's authoritative config.ini ($url) — refusing to probe an inconsistent port" >&2
            return 1
        fi
        url="$WEB3_RPC_URL"
    fi
    echo "$url"
}

# _run_stateroot_oracle <height> <node_dir> [extra_csv] — shared stateroot-oracle runner used by
# every call site (gate.sh, run_case.sh, scenario_upgrade.sh, fuzz_bcos.sh): discover this
# cluster's live Web3 RPC URLs via _discover_stateroot_urls, then feed ALL of them to
# oracle_stateroot.sh (or ${STATEROOT_ORACLE} when a test stubs it) as repeated -r flags, so a
# real cross-node stateRoot comparison actually happens instead of the single-URL "nothing to
# compare" short-circuit every call site used to hit individually.
#
# rc: 0 clean, 1 divergence (oracle_stateroot_decide tripped), 3 infrastructure (<2 node RPCs
# discovered under node_dir — see _discover_stateroot_urls).
#
# CRITICAL: the discover rc is captured via a plain command substitution `urls_text="$(...)"`
# BEFORE mapfile ever runs — `mapfile -t urls < <(_discover_stateroot_urls ...)` would run the
# discovery in a process-substitution subshell whose own exit status never reaches `$?` here (the
# `<()` pipeline's rc is invisible to the reading command), silently swallowing rc=3 and letting a
# single-node cluster fall through as if it were clean. Do not "simplify" this back to a one-liner.
_run_stateroot_oracle() {
    local height="$1" node_dir="$2" extra="${3:-}" urls_text
    if ! urls_text="$(_discover_stateroot_urls "$node_dir" "$extra")"; then return 3; fi
    local -a urls=() rflags=(); mapfile -t urls <<<"$urls_text"
    local u; for u in "${urls[@]}"; do [[ -n "$u" ]] && rflags+=(-r "$u"); done
    bash "${STATEROOT_ORACLE:-$_ORACLE_LIB_DIR/oracle_stateroot.sh}" -b "$height" "${rflags[@]}"
}
