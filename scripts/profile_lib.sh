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

declare -gA PROFILE_META
declare -gA PROFILE_GENESIS
declare -gA PROFILE_REPLAY
declare -gA PROFILE_CONFIG

# profile_load <path> — parse a .profile file into the PROFILE_* arrays.
profile_load() {
    local path="$1"
    PROFILE_META=()
    PROFILE_GENESIS=()
    PROFILE_REPLAY=()
    PROFILE_CONFIG=()

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
                system_config_replay) PROFILE_REPLAY["$key"]="$value" ;;
                config_ini_override) PROFILE_CONFIG["$key"]="$value" ;;
            esac
        fi
    done < "$path"
}

# profile_replay_pairs — print PROFILE_REPLAY entries as "key value" lines.
profile_replay_pairs() {
    local key
    for key in "${!PROFILE_REPLAY[@]}"; do
        echo "$key ${PROFILE_REPLAY[$key]}"
    done
}

# profile_config_pairs — print PROFILE_CONFIG entries as "section.key value" lines.
profile_config_pairs() {
    local key
    for key in "${!PROFILE_CONFIG[@]}"; do
        echo "$key ${PROFILE_CONFIG[$key]}"
    done
}
