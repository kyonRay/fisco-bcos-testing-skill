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
