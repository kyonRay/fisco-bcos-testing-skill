#!/usr/bin/env bash
# failures_lib.sh — local defect sink. The deterministic half of the failures.jsonl /
# report_defects.sh split: gate.sh (pure shell, cron-run) sources this file and calls
# failures_append whenever an oracle trips, appending one JSON line to
# <outdir>/failures.jsonl. ZERO network/cloud dependency lives here — no curl, no mcporter, no
# tencent-docs. The cloud sync (reading failures.jsonl, pushing unreported rows to the Tencent
# smartsheet) lives entirely in scripts/report_defects.sh, invoked separately by the model layer
# (which holds the tencent-docs skill's auth) — never from this file or from gate.sh's own
# real-run path.
#
# This file is SOURCED (by gate.sh, by scripts/report_defects.sh, and by
# tests/failures_lib_test.sh), so it must not `set -e`/`set -u` at file scope: that would change
# the sourcing script's own shell options. Matches scripts/scenarios/scenario_*.sh's convention
# exactly (see e.g. scenario_ut.sh's header note).

# Requires bash 4+ — matches the floor every other scripts/*.sh in this skill declares. Guarded
# with `return` (sourced) falling back to `exit` (executed directly by mistake), same idiom as
# profile_lib.sh / oracle_lib.sh.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "failures_lib.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    return 1 2>/dev/null || exit 1
fi

# _failures_json_escape <value> — minimal JSON string escaping: backslash first (so the
# following substitutions don't double-escape it), then double-quote, then the three control
# characters that would otherwise break a single-line JSON value (newline/tab/CR — desc/repro
# fields are free text and may legitimately contain any of these). Not a general JSON escaper
# (no \uXXXX for other control chars) — sufficient for the free-text fields this file writes.
_failures_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# _gate_scenario_label <phase> — normalize gate.sh's oracle-check phase label into a valid
# 场景族 (scenario family) value for the smartsheet's singleSelect option set
# {ut, dual_rpc, malformed, upgrade, exploration, baseline}. gate.sh's run_oracles_once is called
# once as "baseline" and once per scenario as "after:<scenario>" — the raw phase string
# ("after:ut" etc.) is NOT a valid option, so this strips the "after:" prefix down to the bare
# scenario family name; "baseline" itself is already a valid option and passes through
# unchanged. Pure function, no IO — the only part of this normalization worth unit-testing on
# its own (see tests/failures_lib_test.sh).
_gate_scenario_label() {
    local phase="$1"
    printf '%s' "${phase#after:}"
}

# failures_append <outdir> <profile> <scenario> <oracle> <severity> <desc> <repro> <evidence> <version>
# Append one JSON line to <outdir>/failures.jsonl recording a gate-detected defect:
#   {"profile":...,"scenario":...,"oracle":...,"severity":...,"desc":...,"repro":...,
#    "evidence":...,"version":...,"reported":false,"ts":"<UTC ISO8601>"}
# Pure local file append — no network call anywhere in this function; report_defects.sh reads
# this same file later and is the only piece of this split that talks to the network.
# stdout-purity: this function prints nothing on success (matches scenario_*.sh's convention —
# only report_defects.sh below needs to print machine-parseable output).
failures_append() {
    local outdir="$1" profile="$2" scenario="$3" oracle="$4" severity="$5"
    local desc="$6" repro="$7" evidence="$8" version="$9"
    mkdir -p "$outdir"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"profile":"%s","scenario":"%s","oracle":"%s","severity":"%s","desc":"%s","repro":"%s","evidence":"%s","version":"%s","reported":false,"ts":"%s"}\n' \
        "$(_failures_json_escape "$profile")" \
        "$(_failures_json_escape "$scenario")" \
        "$(_failures_json_escape "$oracle")" \
        "$(_failures_json_escape "$severity")" \
        "$(_failures_json_escape "$desc")" \
        "$(_failures_json_escape "$repro")" \
        "$(_failures_json_escape "$evidence")" \
        "$(_failures_json_escape "$version")" \
        "$ts" \
        >> "$outdir/failures.jsonl"
}
