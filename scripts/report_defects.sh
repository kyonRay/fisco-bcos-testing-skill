#!/usr/bin/env bash
# report_defects.sh — cloud-sync half of the failures.jsonl / failures_lib.sh split (see that
# file's header). Reads <outdir>/failures.jsonl, selects rows with reported==false, maps each to
# a Tencent smartsheet `add_records` payload, and calls `mcporter call tencent-docs
# smartsheet.add_records` to write them, then marks the written rows reported=true (+record_id)
# locally. This is a standalone CLI — unlike failures_lib.sh it is EXECUTED directly (by the
# model layer, which holds the tencent-docs skill's auth), never sourced, so unlike
# failures_lib.sh it does set its own `set -euo pipefail`.
#
# Usage:
#   report_defects.sh <outdir> [--dry-run] [-h]
#     <outdir>    directory containing failures.jsonl (as written by failures_append)
#     --dry-run   print how many unreported records would be added and the add_records JSON
#                 that would be sent, WITHOUT calling mcporter. This is the ONLY path this
#                 skill's own tests exercise — there is no live tencent-docs auth in CI. Guarded
#                 so --dry-run returns before the mcporter call is ever reached.
#     -h          print this help and exit
#
# Coordinates are hardcoded per spec appendix A2 — the smartsheet already exists:
#   file_id=ZgGaGJqoseMl  sheet_id=t00i2h
#
# Column mapping (12 columns, spec A2). 5 are singleSelect (-> option_value.items), the
# remaining 7 are plain text (-> text_value.items):
#   缺陷标题          text          "<profile>/<scenario>/<oracle>"
#   发现时间          text          failures.jsonl's "ts" (UTC ISO8601, as written)
#   画像profile       singleSelect  failures.jsonl's "profile"
#   场景族            singleSelect  failures.jsonl's "scenario"
#   失败信号          singleSelect  failures.jsonl's "oracle"
#   严重级别          singleSelect  failures.jsonl's "severity"
#   现象描述          text          failures.jsonl's "desc"
#   复现输入步骤      text          failures.jsonl's "repro"
#   证据路径          text          failures.jsonl's "evidence"
#   关联版本          text          failures.jsonl's "version"
#   状态              singleSelect  constant "待处理" — failures_append has no state param;
#                                   report_defects always files a fresh defect as pending triage
#   关联case_FIB_PR   text          "" — not tracked by failures_append; filled in manually later
#
# No jq dependency (matches scripts/scenarios/scenario_upgrade.sh /
# scenario_dual_rpc.sh's stated convention) — failures.jsonl lines are flat single-object JSON
# written only by failures_lib.sh's own printf, so a sed-based field extractor is enough; no
# general-purpose JSON parser is needed to round-trip our own output.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "report_defects.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

FILE_ID="ZgGaGJqoseMl"
SHEET_ID="t00i2h"

OUTDIR=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ERROR: unknown flag $1. -h for help." >&2; exit 2 ;;
        *) OUTDIR="$1"; shift ;;
    esac
done

[[ -z "$OUTDIR" ]] && { echo "ERROR: <outdir> is required. -h for help." >&2; exit 2; }
FAILURES_FILE="$OUTDIR/failures.jsonl"
[[ -f "$FAILURES_FILE" ]] || { echo "ERROR: no failures.jsonl at $FAILURES_FILE" >&2; exit 1; }

# _rd_field <line> <key> — pull a quoted string field's value out of one flat failures.jsonl
# JSON object. Uses bash's own [[ =~ ]] (POSIX ERE, alternation via plain `|`) rather than sed:
# BSD sed (macOS default) does not support `\|` alternation in a BRE, so a sed one-liner here
# would silently fail to match on macOS while working on GNU/Linux — bash's regex engine doesn't
# have that split. Handles embedded `\"` (failures_append's own escaping) via `\\.|[^"\\]` so an
# escaped quote inside a value doesn't terminate the match early.
_rd_field() {
    local line="$1" key="$2"
    local re="\"${key}\":\"((\\\\.|[^\"\\\\])*)\""
    if [[ "$line" =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# _rd_reported <line> — "true" or "false" for the unquoted boolean reported field.
_rd_reported() {
    local line="$1"
    if [[ "$line" =~ \"reported\":(true|false) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# _rd_field_text <title> <value> — one text-typed FieldValueEntry.
_rd_field_text() {
    printf '{"field":"%s","text_value":{"items":[{"text":"%s","type":"text"}]}}' "$1" "$2"
}

# _rd_field_option <title> <value> — one singleSelect-typed FieldValueEntry.
_rd_field_option() {
    printf '{"field":"%s","option_value":{"items":[{"text":"%s"}]}}' "$1" "$2"
}

# _rd_record_json <profile> <scenario> <oracle> <severity> <desc> <repro> <evidence> <version> <ts>
# One AddRecord JSON object (field_values array, 12 columns per spec A2). Values are passed
# through as-is: they came out of failures.jsonl, which failures_append already wrote with
# minimal JSON escaping applied, so they are already safe to re-embed as JSON string content
# here — no double-escaping needed. stdout-purity: prints ONLY this JSON object.
_rd_record_json() {
    local profile="$1" scenario="$2" oracle="$3" severity="$4" desc="$5" repro="$6" evidence="$7" version="$8" ts="$9"
    local title="${profile}/${scenario}/${oracle}"
    printf '{"field_values":[%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s]}' \
        "$(_rd_field_text "缺陷标题" "$title")" \
        "$(_rd_field_text "发现时间" "$ts")" \
        "$(_rd_field_option "画像profile" "$profile")" \
        "$(_rd_field_option "场景族" "$scenario")" \
        "$(_rd_field_option "失败信号" "$oracle")" \
        "$(_rd_field_option "严重级别" "$severity")" \
        "$(_rd_field_text "现象描述" "$desc")" \
        "$(_rd_field_text "复现输入步骤" "$repro")" \
        "$(_rd_field_text "证据路径" "$evidence")" \
        "$(_rd_field_text "关联版本" "$version")" \
        "$(_rd_field_option "状态" "待处理")" \
        "$(_rd_field_text "关联case_FIB_PR" "")"
}

# Collect unreported rows: 1-indexed line numbers (for the local rewrite below) and their
# rendered AddRecord JSON (for the request body).
declare -a target_linenos=()
declare -a records_json=()
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ -z "$line" ]] && continue
    [[ "$(_rd_reported "$line")" == "false" ]] || continue
    target_linenos+=("$lineno")
    records_json+=("$(_rd_record_json \
        "$(_rd_field "$line" profile)" \
        "$(_rd_field "$line" scenario)" \
        "$(_rd_field "$line" oracle)" \
        "$(_rd_field "$line" severity)" \
        "$(_rd_field "$line" desc)" \
        "$(_rd_field "$line" repro)" \
        "$(_rd_field "$line" evidence)" \
        "$(_rd_field "$line" version)" \
        "$(_rd_field "$line" ts)")")
done < "$FAILURES_FILE"

count=${#target_linenos[@]}

joined_records=""
if [[ $count -gt 0 ]]; then
    joined_records="$(IFS=,; printf '%s' "${records_json[*]}")"
fi
payload="{\"file_id\":\"$FILE_ID\",\"sheet_id\":\"$SHEET_ID\",\"records\":[$joined_records]}"

if [[ "$DRY_RUN" == 1 ]]; then
    echo "$count records to add"
    echo "$payload"
    exit 0
fi

if [[ $count -eq 0 ]]; then
    echo "report_defects: no unreported failures in $FAILURES_FILE"
    exit 0
fi

echo ">> report_defects: pushing $count record(s) to smartsheet ($FILE_ID/$SHEET_ID)"
response="$(mcporter call tencent-docs smartsheet.add_records --args "$payload")"

# Documented assumption (verified only against a live tencent-docs auth, not by this skill's own
# tests): add_records's response echoes `records` back in the SAME ORDER submitted, one
# "record_id" per added record — same "assumption about external layout, tested only live"
# posture gate.sh's own real-run section takes for cluster PID/RPC discovery.
declare -a record_ids=()
while IFS= read -r id; do
    [[ -n "$id" ]] && record_ids+=("$id")
done < <(printf '%s' "$response" | grep -o '"record_id":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/')

if [[ ${#record_ids[@]} -ne $count ]]; then
    echo "ERROR: report_defects: expected $count record_id(s) back from add_records, got ${#record_ids[@]}. Response: $response" >&2
    echo "ERROR: local $FAILURES_FILE left untouched — rows remain reported=false; re-run once the mismatch is understood." >&2
    exit 1
fi

# Rewrite failures.jsonl in place, flipping only the target lines' reported flag and appending
# their record_id. Plain bash string substitution + temp-file + mv rather than `sed -i`, which
# has incompatible -i syntax between GNU and BSD sed (no other script in this skill uses sed -i).
tmp_out="$(mktemp)"
lineno=0
ri=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ " ${target_linenos[*]} " == *" $lineno "* ]]; then
        id="${record_ids[$ri]}"
        line="${line/\"reported\":false/\"reported\":true,\"record_id\":\"$id\"}"
        ri=$((ri + 1))
    fi
    printf '%s\n' "$line" >> "$tmp_out"
done < "$FAILURES_FILE"
mv "$tmp_out" "$FAILURES_FILE"

echo "report_defects: marked $count record(s) reported=true in $FAILURES_FILE"
