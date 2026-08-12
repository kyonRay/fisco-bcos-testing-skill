#!/usr/bin/env bash
# install.sh — build fbt and lay out a complete installation tree.
#
# The layout is spec §5's, and paths.Resolve derives everything from the binary's own location
# (<root>/bin/fbt means two levels up), so a finished tree can be moved anywhere.
#
#   <prefix>/bin/fbt
#   <prefix>/libexec/fbt/engine.json
#   <prefix>/libexec/fbt/scripts/            entry points + libraries
#   <prefix>/libexec/fbt/scripts/scenarios/  the gate scenario families
#   <prefix>/libexec/fbt/tools/              tamper-helper.sh
#   <prefix>/share/fbt/profiles/             the captured profiles
#   <prefix>/share/fbt/cases/                the read-only regression fixtures
#
# THREE THINGS THIS SCRIPT EXISTS TO GET RIGHT, each of which broke a real run:
#
#   1. The exec bit. The whole repository once shipped at 0644, and nothing noticed, because
#      every bash test invokes scripts as `bash x.sh` while the host EXECS them. `cp -r` preserves
#      mode, but a tarball built by other means may not, so the modes are set explicitly here and
#      verified at the end.
#   2. scripts/scenarios/ must stay a SUBDIRECTORY. gate.sh sources "$SCRIPT_DIR/scenarios/*.sh";
#      flattening it into scripts/ makes every scenario silently unregistered, and gate.sh then
#      reports "scenario 'ut' selected but not registered" -- for an install that contains all the
#      files, just in the wrong shape.
#   3. The sibling fisco-bcos-testing scripts (cluster_up.sh, run_ut.sh, stop_all.sh) are COPIED
#      IN. An installed tree has no sibling checkout to resolve them from, and their absence is
#      only discovered when a run tries to build a chain.
#
# Usage:
#   ./install.sh [--prefix DIR] [--sibling DIR] [--no-sibling] [--binary PATH]
#
#   --prefix DIR    where to install (default: ./dist)
#   --sibling DIR   the fisco-bcos-testing skill checkout to copy engine scripts from
#                   (default: ../fisco-bcos-testing)
#   --no-sibling    skip the sibling copy; `fbt doctor` will report what is missing
#   --binary PATH   install this prebuilt fbt instead of compiling one. The machines that run a
#                   gate round are test runners with a FISCO build on them, not Go workstations --
#                   requiring a toolchain there would mean installing Go on every one. Cross-build
#                   with `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build ./cmd/fbt` and pass it.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "install.sh requires bash >= 4 (found ${BASH_VERSION}). On macOS: brew install bash." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$SRC/dist"
SIBLING="$SRC/../fisco-bcos-testing"
WANT_SIBLING=1
PREBUILT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --sibling) SIBLING="$2"; shift 2 ;;
        --no-sibling) WANT_SIBLING=0; shift ;;
        --binary) PREBUILT="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag $1; -h for help" >&2; exit 2 ;;
    esac
done

if [[ -n "$PREBUILT" ]]; then
    [[ -f "$PREBUILT" ]] || { echo "ERROR: --binary $PREBUILT does not exist" >&2; exit 1; }
else
    command -v go >/dev/null || {
        echo "ERROR: go is not on PATH. Cross-build elsewhere and pass --binary PATH." >&2
        exit 1
    }
fi

mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"
LIBEXEC="$PREFIX/libexec/fbt"
SHARE="$PREFIX/share/fbt"

mkdir -p "$PREFIX/bin"
if [[ -n "$PREBUILT" ]]; then
    echo ">> installing prebuilt fbt from $PREBUILT"
    cp "$PREBUILT" "$PREFIX/bin/fbt"
    chmod 755 "$PREFIX/bin/fbt"
else
    echo ">> building fbt"
    # CGO_ENABLED=0 so the binary carries no dynamic libc dependency and a tree built on one machine
    # runs on another. The build runs in a SUBSHELL rather than with `go build -C`, which needs Go
    # 1.20 while this module targets 1.19 -- and the failure is a bare "flag provided but not defined".
    ( cd "$SRC" && CGO_ENABLED=0 go build -o "$PREFIX/bin/fbt" ./cmd/fbt )
fi

echo ">> laying out $PREFIX"
rm -rf "$LIBEXEC" "$SHARE"
mkdir -p "$LIBEXEC/scripts/scenarios" "$LIBEXEC/tools" "$SHARE/profiles" "$SHARE/cases"

cp "$SRC/engine.json" "$LIBEXEC/engine.json"
cp "$SRC"/scripts/*.sh "$LIBEXEC/scripts/"
cp "$SRC"/scripts/scenarios/*.sh "$LIBEXEC/scripts/scenarios/"   # see note 2 in the header
cp "$SRC"/tools/tamper-fuzz/tamper-helper.sh "$LIBEXEC/tools/"
# The helper is a wrapper around a jar. Shipping the wrapper alone left the malformed scenario
# unable to run at all, and it failed mid-round as though the CHAIN were at fault. The jar is a
# gradle artifact rather than a checked-in file, so it may legitimately be absent -- say which.
TAMPER_JAR="$SRC/tools/tamper-fuzz/build/libs/tamper-fuzz-all.jar"
if [[ -f "$TAMPER_JAR" ]]; then
    cp "$TAMPER_JAR" "$LIBEXEC/tools/tamper-fuzz-all.jar"
else
    echo "WARNING: tamper-fuzz-all.jar is not built; the 'malformed' scenario will be unavailable." >&2
    echo "         Build it with: (cd $SRC/tools/tamper-fuzz && ./gradlew shadowJar)" >&2
fi
cp "$SRC"/profiles/*.profile "$SHARE/profiles/"
# .case files only: the directory also holds README.md and .gitkeep, and a registry enumeration
# that tripped over those would refuse to run at all.
shopt -s nullglob
for c in "$SRC"/scenarios/*.case; do cp "$c" "$SHARE/cases/"; done
shopt -u nullglob

if (( WANT_SIBLING )); then
    if [[ -d "$SIBLING/scripts" ]]; then
        echo ">> copying sibling engine scripts from $SIBLING"
        for n in cluster_up.sh stop_all.sh start_all.sh run_ut.sh; do
            [[ -f "$SIBLING/scripts/$n" ]] && cp "$SIBLING/scripts/$n" "$LIBEXEC/scripts/"
        done
    else
        echo "WARNING: no fisco-bcos-testing checkout at $SIBLING." >&2
        echo "         Chain-building runs will fail with 'cluster_up.sh not found' (exit 30)." >&2
        echo "         Pass --sibling DIR, or --no-sibling to silence this." >&2
    fi
fi

# ---- modes ----
# Entry points and scenario files are executable; libraries are not. An executable library invites
# someone to run one, and running a library that expects to be sourced fails in a way that reads
# like a broken install.
LIBRARIES=(event_lib.sh profile_lib.sh oracle_lib.sh failures_lib.sh)
chmod 755 "$LIBEXEC/scripts"/*.sh "$LIBEXEC/scripts/scenarios"/*.sh "$LIBEXEC/tools"/*.sh
for lib in "${LIBRARIES[@]}"; do
    [[ -f "$LIBEXEC/scripts/$lib" ]] && chmod 644 "$LIBEXEC/scripts/$lib"
done
chmod 644 "$LIBEXEC/engine.json" "$SHARE/profiles"/*.profile
shopt -s nullglob
for c in "$SHARE/cases"/*.case; do chmod 644 "$c"; done
shopt -u nullglob

# ---- verify, rather than assume ----
# Every one of these checks corresponds to a way an install has actually been wrong.
fail=0
for n in gate.sh run_case.sh apply_profile.sh fuzz_bcos.sh gate_upgrade.sh cluster_down.sh; do
    [[ -x "$LIBEXEC/scripts/$n" ]] || { echo "BROKEN: $n is missing or not executable" >&2; fail=1; }
done
for lib in "${LIBRARIES[@]}"; do
    [[ -f "$LIBEXEC/scripts/$lib" ]] || { echo "BROKEN: library $lib is missing" >&2; fail=1; }
done
[[ -d "$LIBEXEC/scripts/scenarios" ]] || { echo "BROKEN: scripts/scenarios/ was flattened" >&2; fail=1; }
compgen -G "$LIBEXEC/scripts/scenarios/scenario_*.sh" >/dev/null \
    || { echo "BROKEN: no scenario families were installed" >&2; fail=1; }
compgen -G "$SHARE/profiles/*.profile" >/dev/null \
    || { echo "BROKEN: no profiles were installed" >&2; fail=1; }
(( fail )) && exit 1

# The binary must be able to read its own installation from where it now sits. This catches a
# layout that looks right to a human but that paths.Resolve derives differently.
"$PREFIX/bin/fbt" --engine-dir "$PREFIX" --state-dir "$PREFIX/state" config path >/dev/null || {
    echo "BROKEN: the installed fbt cannot resolve its own layout" >&2
    exit 1
}

echo ">> installed to $PREFIX"
echo "   $PREFIX/bin/fbt --help"
