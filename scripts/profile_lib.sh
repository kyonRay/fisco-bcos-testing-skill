#!/usr/bin/env bash
# Declarative .profile parser. Source this file; do not execute directly.
#
# Format (INI-like):
#   [section]
#   key = value
#   # comment
#   (blank lines skipped)
#
# Section -> array mapping:
#   [meta]                  -> PROFILE_META
#   [genesis]                -> PROFILE_GENESIS
#   [system_config_replay]   -> PROFILE_REPLAY
#   [config_ini_override]    -> PROFILE_CONFIG
set -euo pipefail

# Requires bash 4+ (associative arrays). Fail clearly instead of a cryptic
# `declare: -gA: invalid option` on stock macOS bash 3.2.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "profile_lib.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    return 1 2>/dev/null || exit 1
fi

declare -gA PROFILE_META
declare -gA PROFILE_GENESIS
declare -gA PROFILE_REPLAY
declare -gA PROFILE_CONFIG

# Replay is ORDER-SENSITIVE and an associative array has no order: iterating "${!PROFILE_REPLAY[@]}"
# yields bash's hash order, so the same profile can replay its flags in a different sequence on a
# different machine. That is not cosmetic — Features.cpp:37-46 rejects feature_balance_precompiled
# before feature_balance, and feature_balance_policy1 before feature_balance_precompiled. Keep the
# file's own key order alongside the maps and iterate THAT.
declare -ga PROFILE_REPLAY_ORDER
declare -ga PROFILE_CONFIG_ORDER

# profile_load <path> — parse a .profile file into the PROFILE_* arrays.
profile_load() {
    local path="$1"
    PROFILE_META=()
    PROFILE_GENESIS=()
    PROFILE_REPLAY=()
    PROFILE_CONFIG=()
    PROFILE_REPLAY_ORDER=()
    PROFILE_CONFIG_ORDER=()

    local section=""
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        if [[ "$line" =~ ^\[([a-zA-Z0-9_]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$line" == *"="* ]]; then
            local key value
            key="${line%%=*}"
            value="${line#*=}"
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            case "$section" in
                meta) PROFILE_META["$key"]="$value" ;;
                genesis) PROFILE_GENESIS["$key"]="$value" ;;
                system_config_replay)
                    [[ -v PROFILE_REPLAY["$key"] ]] || PROFILE_REPLAY_ORDER+=("$key")
                    PROFILE_REPLAY["$key"]="$value"
                    ;;
                config_ini_override)
                    [[ -v PROFILE_CONFIG["$key"] ]] || PROFILE_CONFIG_ORDER+=("$key")
                    PROFILE_CONFIG["$key"]="$value"
                    ;;
            esac
        fi
    done < "$path"
}

# profile_replay_pairs — print PROFILE_REPLAY entries as "key value" lines, in the profile file's
# own order (see PROFILE_REPLAY_ORDER above — this order is load-bearing, not cosmetic).
profile_replay_pairs() {
    local key
    for key in ${PROFILE_REPLAY_ORDER+"${PROFILE_REPLAY_ORDER[@]}"}; do
        echo "$key ${PROFILE_REPLAY[$key]}"
    done
}

# profile_config_pairs — print PROFILE_CONFIG entries as "section.key value" lines, in file order.
profile_config_pairs() {
    local key
    for key in ${PROFILE_CONFIG_ORDER+"${PROFILE_CONFIG_ORDER[@]}"}; do
        echo "$key ${PROFILE_CONFIG[$key]}"
    done
}
