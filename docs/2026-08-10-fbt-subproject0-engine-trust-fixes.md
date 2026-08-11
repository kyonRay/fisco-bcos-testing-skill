# Sub-project 0: Engine Trust & Relocatability Fixes — Implementation Plan (rev2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the bash-engine defects that make the release-gate's full sweep give false greens or block an installed `libexec` layout — the prerequisite for the `fbt` Go host (sub-project 1).

**Architecture:** Pure bash changes. **Testing discipline (learned from review):** every fix extracts a *pure function* (arg-builder, resolver, port calculator, swap helper) that a test drives directly with real inputs + boundary cases + spies — never a dry-run string assertion that would pass before the fix. Live-chain IO stays manual.

**Tech Stack:** bash 4.0+ (no `nameref`/`declare -n` — builders fill a conventional global array), `tests/assert.sh`, fake `build_chain`/`config.ini`/node-root fixtures created inside tests.

## Global Constraints

- Repo: `/Users/kyonguo/CLionProjects/FISCO-BCOS/.claude/skills/fisco-bcos-release-gate` (nested git repo); `cluster_up.sh`/`run_ut.sh` live in the `../fisco-bcos-testing` sibling.
- Never change an oracle's judgment algorithm (`oracle_*_decide`).
- **Verified current-state facts (do not re-assert as "fixes"):** `apply_profile.sh:63` already rejects a missing `compatibility_version` and its dry-run already prints it — the gap is only the real-path `-v` passthrough to `cluster_up.sh`. `gate.sh`/`run_case.sh` do **not** source `oracle_lib.sh`. `cluster_up.sh` hardcodes `WEB3_BASE=8545` (line 92) **and** `WEB3_PORT=8545` in the readiness probe (line 135). `run_case.sh:171` treats the profile as a file path. `run_case_test.sh:7` pins `profiles/default-latest.profile`. `scenario_ut.sh` hardcodes the sibling `run_ut.sh` path and walks up from its own dir for the repo root. The sibling `cluster_up.sh`/`run_ut.sh` have **no** bash-version guard.
- bash 4.0+; arrays passed with quoted expansion `"${arr[@]}"`, never unquoted string splitting.
- Every existing test stays green: `for t in tests/*_test.sh; do bash "$t"; done`.
- Commits use `COMMIT_VERIFIED=1` prefix (pre-commit hook) after showing test output; no `Co-Authored-By`.

---

## Design Decisions (rev3 — AUTHORITATIVE; override task text on any conflict)

1. **fuzz infra rc=3 terminates.** `_run_stateroot_oracle` rc=3 must propagate out of `_fuzz_oracle_check_once` and **end the fuzz run immediately** with an infrastructure error — never warn-and-continue, never enter trip/bisect. (Task 2)
2. **Primary Web3 URL from final topology.** Add `_primary_web3_url <node_dir>` (in `oracle_lib.sh`) = node0's **final `config.ini`** Web3 URL (or host-injected `WEB3_RPC_URL` when set, asserted consistent with the authoritative base port). `gate.sh`/`run_case.sh` derive their liveness/height `RPC_URL` from it, so every probe uses the same effective port even when `WEB3_BASE` overrides the profile. Test `_primary_web3_url` directly against a fake node0 config. (Tasks 2/4)
3. **Vendoring happens in sub-project 0 (spec-conformant).** Task 7 moves the real `cluster_up.sh`/`run_ut.sh` into the engine's `scripts/` as the **single source of truth**; the `../fisco-bcos-testing` copies become thin `exec` shims that re-run the engine copy. `_resolve_engine_script` order: `$FBT_ENGINE_SCRIPTS` → engine `scripts/` → sibling shim. Test simulates a **no-sibling** libexec layout, and covers the `run_ut.sh` resolver too.
4. **`RG_FUZZ_PROFILE_NAME` required.** The fuzz `.case` writer takes the logical profile name as a **required** input (the driver sets it from the profile actually in use) — no silent `production-enterprise` default. Missing → the writer errors. Add the key to sub-project 1's env-translation table. (Task 8)
5. **Scenario-validation classes are distinct.** unknown-name / `upgrade`-selection → **config error** (exit `2`, maps to sub-project 1 `20`); **known-but-unregistered → engine/setup fault** (distinct exit, maps to `40`) — a scenario that should run but its file didn't register. Never conflate the two, and neither is `10`. (Task 5)
6. **One dry-run output contract.** `run_case` dry-run echoes the **logical profile name** (stable), not a resolved absolute path. `_run_case_resolve_profile` handles an **absolute** path as-is (no join to case dir). Task 2 adds the gate dry-run line `stateroot oracle -> discover >=2 node Web3 RPC URLs at runtime`. Also update `scenarios/README.md` (case format now carries `status`) and sync sub-0 spec line ~117 (`schema_version` → the three-field set). (Tasks 2/8)
7. **T3/T4 get real spy tests (not only pure-fn extraction).** Add a fake `build_chain.sh` that appends `"$@"` to a log, plus a no-node test entry (run only generate+patch, `start_all` stubbed) asserting: the real call site uses the array (spaces preserved), **both** download/non-download paths route through the builder, readiness uses `-w`, and a non-default `-w 18545` actually lands as `listen_port` in `node<i>/config.ini` = `18545+i`; and that `apply_profile.sh`'s real call passed `-v/-n/-p/-w/-s/-e`.

Mechanical residue (IPv6 case, unbound vars, array-vs-env slips) is caught by each task's Step 2/Step 4 run — implementers adapt exact bash to reality; a task is not done until its test genuinely fails without the fix and passes with it.

---

### Task 1: `_discover_stateroot_urls` pure helper (exact-key parse, IPv6-safe, ≥2-or-rc3)

**Files:** Modify `scripts/oracle_lib.sh`; Test `tests/stateroot_discovery_test.sh` (create).

**Interfaces — Produces:** `_discover_stateroot_urls <node_dir> [extra_csv]` → one URL per line (deduped, sorted) for each node whose `[web3_rpc] enable=true`; appends `extra_csv`; normalizes `0.0.0.0`→`127.0.0.1`, brackets any IPv6 literal; returns `3` on stderr when <2 URLs.

- [ ] **Step 1: Write the failing test**
```bash
#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"; source "$SD/../scripts/oracle_lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"/node{0,1,2}
printf '[web3_rpc]\n    enable=true\n    listen_ip=0.0.0.0\n    listen_port=8545\n' > "$tmp/node0/config.ini"
printf '[web3_rpc]\n    enable=true\n    listen_ip=::\n    listen_port=8546\n'      > "$tmp/node1/config.ini"
printf '[web3_rpc]\n    enable=false\n    listen_port=8547\n'                        > "$tmp/node2/config.ini"
out="$(_discover_stateroot_urls "$tmp")"
assert_contains "$out" "http://127.0.0.1:8545" "0.0.0.0 -> loopback"
assert_contains "$out" "http://[::1]:8546" "IPv6 :: -> [::1] bracketed"
assert_not_contains "$out" "8547" "web3-disabled node excluded"
out2="$(_discover_stateroot_urls "$tmp" "http://x:9,http://127.0.0.1:8545")"
assert_eq "1" "$(printf '%s\n' "$out2" | grep -c '127.0.0.1:8545')" "duplicate collapsed"
assert_contains "$out2" "http://x:9" "extra appended"
solo="$(mktemp -d)"; mkdir -p "$solo/node0"; printf '[web3_rpc]\n    enable=true\n    listen_port=8545\n' > "$solo/node0/config.ini"
rc=0; _discover_stateroot_urls "$solo" >/dev/null 2>&1 || rc=$?; assert_eq "3" "$rc" "<2 -> rc3"; rm -rf "$solo"
assert_done
```
- [ ] **Step 2: Run — expect FAIL** (`command not found`): `bash tests/stateroot_discovery_test.sh`
- [ ] **Step 3: Implement** — append to `scripts/oracle_lib.sh`:
```bash
_discover_stateroot_urls() {
    local node_dir="$1" extra_csv="${2:-}" cfg enabled host port
    local -a urls=()
    # exact-key reader within [web3_rpc]: trim spaces around key, match key == want
    _w3() { awk -F= -v want="$2" '
        /^[[:space:]]*\[/{s=($0 ~ /\[web3_rpc\]/)}
        s && $1 ~ /=/{next}
        s { k=$1; gsub(/[[:space:]]/,"",k); if (k==want){v=$2; gsub(/[[:space:]]/,"",v); print v} }
    ' "$1" | tail -n1; }
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
```
- [ ] **Step 4: Run — expect PASS**: `bash tests/stateroot_discovery_test.sh`
- [ ] **Step 5: Commit**
```bash
git add scripts/oracle_lib.sh tests/stateroot_discovery_test.sh
COMMIT_VERIFIED=1 git commit -m "fix(oracle): _discover_stateroot_urls multi-node helper (sub0 fix1)"
```

---

### Task 2: `_run_stateroot_oracle` shared runner + wire all FOUR call sites (gate, run_case, upgrade, fuzz)

**Files:** Modify `scripts/oracle_lib.sh` (runner), `scripts/gate.sh`, `scripts/run_case.sh`, `scripts/scenarios/scenario_upgrade.sh`, `scripts/fuzz_bcos.sh` (source lib + call runner); Test `tests/run_stateroot_oracle_test.sh` (create).

**Interfaces — Produces:** `_run_stateroot_oracle <height> <node_dir> <extra_csv>` → `0` clean, `1` divergence, `3` infrastructure (<2 nodes). Captures the discover rc **before** `mapfile` (the process-substitution rc trap). Calls `${STATEROOT_ORACLE:-<lib_dir>/oracle_stateroot.sh}` so tests stub it. **Consumes:** `_discover_stateroot_urls` (Task 1). All four sites source `oracle_lib.sh` and map rc: `3`→infra failure, `1`→stateroot tripped, `0`→ok.

- [ ] **Step 1: Write the failing test**
```bash
#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"; source "$SD/../scripts/oracle_lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/two"/node{0,1}
printf '[web3_rpc]\n enable=true\n listen_port=8545\n' > "$tmp/two/node0/config.ini"
printf '[web3_rpc]\n enable=true\n listen_port=8546\n' > "$tmp/two/node1/config.ini"
mkdir -p "$tmp/one/node0"; printf '[web3_rpc]\n enable=true\n listen_port=8545\n' > "$tmp/one/node0/config.ini"
export STATEROOT_ORACLE="$tmp/fake.sh" RFLAGS="$tmp/rflags"
printf '#!/usr/bin/env bash\necho "$@" >> "$RFLAGS"\nexit "${FAKE_RC:-0}"\n' > "$STATEROOT_ORACLE"; chmod +x "$STATEROOT_ORACLE"
rc=0; FAKE_RC=0 _run_stateroot_oracle 5 "$tmp/two" "" || rc=$?; assert_eq "0" "$rc" "clean -> 0"
assert_contains "$(cat "$RFLAGS")" "-r http://127.0.0.1:8545" "both urls passed as -r"
assert_contains "$(cat "$RFLAGS")" "-r http://127.0.0.1:8546" "second url passed"
rc=0; FAKE_RC=1 _run_stateroot_oracle 5 "$tmp/two" "" || rc=$?; assert_eq "1" "$rc" "divergence -> 1"
rc=0; _run_stateroot_oracle 5 "$tmp/one" "" || rc=$?; assert_eq "3" "$rc" "single node -> infra 3 (oracle not consulted)"
assert_done
```
- [ ] **Step 2: Run — expect FAIL**: `bash tests/run_stateroot_oracle_test.sh`
- [ ] **Step 3: Implement** — in `scripts/oracle_lib.sh` add (near top: `_ORACLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`):
```bash
_run_stateroot_oracle() {
    local height="$1" node_dir="$2" extra="${3:-}" urls_text
    if ! urls_text="$(_discover_stateroot_urls "$node_dir" "$extra")"; then return 3; fi   # rc captured BEFORE mapfile
    local -a urls=() rflags=(); mapfile -t urls <<<"$urls_text"
    local u; for u in "${urls[@]}"; do [[ -n "$u" ]] && rflags+=(-r "$u"); done
    bash "${STATEROOT_ORACLE:-$_ORACLE_LIB_DIR/oracle_stateroot.sh}" -b "$height" "${rflags[@]}"
}
```
Then at each site add `source "<dir>/oracle_lib.sh"` if absent and replace the single-`-r` stateroot block:
- `gate.sh` `run_oracles_once`:
```bash
    local sr_rc=0; _run_stateroot_oracle "$height" "$NODE_DIR" "${RG_FUZZ_STATEROOT_URLS:-}" || sr_rc=$?
    if [[ "$sr_rc" == 3 ]]; then echo "ERROR: stateroot ($phase): <2 node RPCs discovered under $NODE_DIR" >&2; rc=1
    elif [[ "$sr_rc" == 1 ]]; then rc=1; failures_append "$FAILURES_OUTDIR" "$profile_name" "$scenario_label" "state-mismatch" "高" "oracle_stateroot tripped during $phase @ $height" "bash $SCRIPT_DIR/gate.sh -p $PROFILE_PATH" "$NODE_DIR" "${PROFILE_GENESIS[compatibility_version]:-unknown}"; fi
```
- `run_case.sh`: same, setting `stateroot_tripped=1` on rc 1, and a distinct non-zero exit path on rc 3.
- `scenario_upgrade.sh` per-node sampling: replace with `_run_stateroot_oracle "$height" "$node_dir" ""` and treat rc 1 as fork.
- `fuzz_bcos.sh` `_fuzz_oracle_check_once`: replace its stateroot branch (currently gated on `RG_FUZZ_STATEROOT_URLS`) so it **always** runs `_run_stateroot_oracle "$height" "$NODE_DIR" "${RG_FUZZ_STATEROOT_URLS:-}"`; rc 3 → warn+treat as infra (non-scoring), rc 1 → `_FUZZ_LAST_STATEROOT_TRIPPED=1`.
- [ ] **Step 4: Run — expect PASS** (unit + all four sites' existing tests):
`bash tests/run_stateroot_oracle_test.sh && for t in oracle gate run_case scenario_upgrade fuzz_bcos; do bash tests/${t}_test.sh; done`
- [ ] **Step 5: Commit**
```bash
git add scripts/oracle_lib.sh scripts/gate.sh scripts/run_case.sh scripts/scenarios/scenario_upgrade.sh scripts/fuzz_bcos.sh tests/run_stateroot_oracle_test.sh
COMMIT_VERIFIED=1 git commit -m "fix(oracle): shared _run_stateroot_oracle; wire gate/run_case/upgrade/fuzz (sub0 fix1)"
```

---

### Task 3: `_cluster_up_build_chain_argv` global-array builder + `-v/-w/-e/-n/-p/-s`; readiness probe uses effective Web3 base; bash guard

**Files:** Modify `../fisco-bcos-testing/scripts/cluster_up.sh` (+ `run_ut.sh` bash guard); Test `tests/cluster_up_argv_test.sh` (create).

**Interfaces — Produces:** `_cluster_up_build_chain_argv <nodes> <ports> <outdir> <fisco_bin> <sm_flag> <version> <web3_base>` fills global array `BUILD_CHAIN_ARGV`; empty version/binary omit `-v`/`-e`. `cluster_up.sh` gains `-v <ver>` `-w <web3_base>`; readiness probe and Web3-enable renumber both use the effective base.

- [ ] **Step 1: Write the failing test**
```bash
#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
eval "$(sed -n '/^_cluster_up_build_chain_argv()/,/^}/p' "$SD/../../fisco-bcos-testing/scripts/cluster_up.sh")"
_cluster_up_build_chain_argv 4 "30300,20200" "/tmp/o u t" "/bin/f i" "" "3.0.0" ""
printf '%s\n' "${BUILD_CHAIN_ARGV[@]}" | grep -Fxq "/tmp/o u t" && ok=1 || ok=0
assert_eq "1" "$ok" "spaced outdir kept as ONE argv element"
printf '%s\n' "${BUILD_CHAIN_ARGV[@]}" | grep -Fxq "/bin/f i" && ok=1 || ok=0
assert_eq "1" "$ok" "spaced binary kept as ONE element"
assert_contains " ${BUILD_CHAIN_ARGV[*]} " " -v 3.0.0 " "version present"
_cluster_up_build_chain_argv 4 "30300,20200" /tmp/o "" "-s" "" ""
assert_not_contains " ${BUILD_CHAIN_ARGV[*]} " " -v " "no version -> no -v"
assert_not_contains " ${BUILD_CHAIN_ARGV[*]} " " -e " "no binary -> no -e"
assert_contains " ${BUILD_CHAIN_ARGV[*]} " " -s " "SM flag present"
assert_done
```
- [ ] **Step 2: Run — expect FAIL**: `bash tests/cluster_up_argv_test.sh`
- [ ] **Step 3: Implement** — in `cluster_up.sh` add a bash guard at top (mirror the release-gate scripts' `[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo "needs bash 4+"; exit 1; }`), the builder, and route the two `bash "$BUILD_CHAIN" ...` calls through it **quoted**:
```bash
_cluster_up_build_chain_argv() {
    BUILD_CHAIN_ARGV=(-p "$2" -l "127.0.0.1:$1" -o "$3")
    [[ -n "$4" ]] && BUILD_CHAIN_ARGV+=(-e "$4")
    [[ -n "$6" ]] && BUILD_CHAIN_ARGV+=(-v "$6")
    [[ -n "$5" ]] && BUILD_CHAIN_ARGV+=("$5")
}
# ... in getopts add v: and w: ; set COMPAT_VERSION / WEB3_BASE from them (WEB3_BASE default 8545)
_cluster_up_build_chain_argv "$NODES" "$PORTS" "$OUTDIR" "${FISCO_BIN:-}" "$SM_FLAG" "${COMPAT_VERSION:-}" "$WEB3_BASE"
bash "$BUILD_CHAIN" "${BUILD_CHAIN_ARGV[@]}"
```
Replace the hardcoded `WEB3_BASE=8545` (line 92) with the `-w`-provided value (default 8545), and the readiness-probe `WEB3_PORT=8545` (line 135) with `WEB3_PORT="$WEB3_BASE"`. Add the same bash guard to `run_ut.sh`.
- [ ] **Step 4: Run — expect PASS**: `bash tests/cluster_up_argv_test.sh` (and confirm `build_chain.sh` accepts `-v`; if not, builder patches `config.genesis` instead — decide before Step 5).
- [ ] **Step 5: Commit** (sibling repo + this repo's test):
```bash
git -C ../fisco-bcos-testing add scripts/cluster_up.sh scripts/run_ut.sh
git -C ../fisco-bcos-testing commit -m "feat(cluster_up): array argv builder, -v/-w passthrough, effective web3 base, bash guard (sub0 fix2/6)"
git add tests/cluster_up_argv_test.sh
COMMIT_VERIFIED=1 git commit -m "test: cluster_up argv builder boundaries (sub0 fix2/6)"
```

---

### Task 4: apply_profile passes `-v` + topology (pure arg-builder + spy); Web3 base outranks profile patch

**Files:** Modify `scripts/apply_profile.sh`; Test `tests/apply_profile_passthrough_test.sh` (create — its own harness vars, not the existing file's).

**Interfaces — Produces:** `_apply_profile_cluster_up_args <outdir> <version> <fisco_bin> <node_count> <ports> <web3_base> <sm_mode>` fills global `APPLY_CU_ARGS`. `_apply_profile_web3_port <profile_listen_port> <node_index> <web3_base_override>` returns the port to write (override base wins). **Consumes:** `cluster_up.sh -v/-w` (Task 3). Note: the required-`compatibility_version` guard already exists (line 63) — untouched.

- [ ] **Step 1: Write the failing test**
```bash
#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
eval "$(sed -n '/^_apply_profile_cluster_up_args()/,/^}/p' "$SD/../scripts/apply_profile.sh")"
eval "$(sed -n '/^_apply_profile_web3_port()/,/^}/p' "$SD/../scripts/apply_profile.sh")"
_apply_profile_cluster_up_args "/o u t" "3.0.0" "/bin/f i" "4" "30300,20200" "18545" "1"
printf '%s\n' "${APPLY_CU_ARGS[@]}" | grep -Fxq "/o u t" && ok=1 || ok=0; assert_eq "1" "$ok" "spaced outdir one element"
assert_contains " ${APPLY_CU_ARGS[*]} " " -v 3.0.0 " "version threaded"
assert_contains " ${APPLY_CU_ARGS[*]} " " -w 18545 " "web3 base threaded"
assert_contains " ${APPLY_CU_ARGS[*]} " " -s " "SM threaded"
assert_eq "18547" "$(_apply_profile_web3_port 8545 2 18545)" "override base wins: 18545+2"
assert_eq "8547"  "$(_apply_profile_web3_port 8545 2 '')"    "no override: profile base 8545+2"
assert_done
```
- [ ] **Step 2: Run — expect FAIL**: `bash tests/apply_profile_passthrough_test.sh`
- [ ] **Step 3: Implement** — in `scripts/apply_profile.sh` add the two pure functions; build `APPLY_CU_ARGS` and call `bash "$CLUSTER_UP" "${APPLY_CU_ARGS[@]}"` (replacing `bash "$CLUSTER_UP" -o "$OUTDIR"`); in the config.ini patch loop, for a `web3_rpc.*listen_port` key use `_apply_profile_web3_port "$value" "$idx" "${WEB3_BASE:-}"` so a host-provided `WEB3_BASE` overrides the profile's port (other listen_port keys keep the existing base+idx renumber). Mirror `APPLY_CU_ARGS` into the `--dry-run` plan text.
- [ ] **Step 4: Run — expect PASS**: `bash tests/apply_profile_passthrough_test.sh && bash tests/apply_profile_test.sh`
- [ ] **Step 5: Commit**
```bash
git add scripts/apply_profile.sh tests/apply_profile_passthrough_test.sh
COMMIT_VERIFIED=1 git commit -m "fix(apply_profile): thread -v+topology via array; web3 base outranks profile patch (sub0 fix2/6)"
```

---

### Task 5: gate set = four families; `upgrade` selection & unknown & known-but-unregistered all fail (pure validator)

**Files:** Modify `scripts/gate.sh` (`GATE_KNOWN_SCENARIOS`, drop `GATE_SCENARIOS_NEEDS_ARGS`, validator, run-loop); Test `tests/gate_test.sh` (extend + rewrite the stale upgrade assertion).

**Interfaces — Produces:** `_gate_validate_scenarios <known_csv> <registered_csv> <name...>` → prints error + returns `2` on `upgrade`, unknown, or known-but-unregistered; else `0`.

- [ ] **Step 1: Write the failing test** — first **rewrite** `gate_test.sh:17`'s assertion that the default set contains `upgrade` to assert it does **not**; then append:
```bash
eval "$(sed -n '/^_gate_validate_scenarios()/,/^}/p' scripts/gate.sh)"
rc=0; _gate_validate_scenarios "ut dual_rpc malformed jsd" "ut malformed" upgrade 2>/dev/null || rc=$?; assert_eq "2" "$rc" "upgrade selected -> 2"
msg="$(_gate_validate_scenarios "ut" "ut" upgrade 2>&1 || true)"; assert_contains "$msg" "gate upgrade" "points to gate upgrade"
rc=0; _gate_validate_scenarios "ut malformed" "ut malformed" nonesuch 2>/dev/null || rc=$?; assert_eq "2" "$rc" "unknown -> 2"
rc=0; _gate_validate_scenarios "ut malformed" "ut" malformed 2>/dev/null || rc=$?; assert_eq "2" "$rc" "known-but-unregistered -> 2"
rc=0; _gate_validate_scenarios "ut malformed" "ut malformed" ut malformed 2>/dev/null || rc=$?; assert_eq "0" "$rc" "all good -> 0"
```
- [ ] **Step 2: Run — expect FAIL**: `bash tests/gate_test.sh`
- [ ] **Step 3: Implement** — in `gate.sh`: set `GATE_KNOWN_SCENARIOS="ut dual_rpc malformed jsd"`; delete `GATE_SCENARIOS_NEEDS_ARGS` and its skip branch; add:
```bash
_gate_validate_scenarios() {
    local known="$1" registered="$2"; shift 2; local n
    for n in "$@"; do
        [[ "$n" == "upgrade" ]] && { echo "ERROR: 'upgrade' is not a gate scenario; run: fbt gate upgrade -p <profile> --old-bin <p> --new-bin <p> --target-ver <v>" >&2; return 2; }
        [[ " $known " == *" $n "* ]]      || { echo "ERROR: unknown scenario '$n'" >&2; return 2; }
        [[ " $registered " == *" $n "* ]] || { echo "ERROR: scenario '$n' selected but not registered" >&2; return 2; }
    done; return 0
}
```
Call it after building `scenario_list` (registered set = `"${!GATE_SCENARIOS[*]}"`), exiting `2` on failure. Remove the now-dead unregistered `SKIP` branch in the run loop (validation already guaranteed registration).
- [ ] **Step 4: Run — expect PASS**: `bash tests/gate_test.sh`
- [ ] **Step 5: Commit**
```bash
git add scripts/gate.sh tests/gate_test.sh
COMMIT_VERIFIED=1 git commit -m "fix(gate): four-family set + _gate_validate_scenarios (sub0 fix3)"
```

---

### Task 6: Upgrade — atomic swap helper (real fixture), old_bin T0, profile-path parameter

**Files:** Modify `scripts/scenarios/scenario_upgrade.sh`; Test `tests/upgrade_swap_test.sh` (create).

**Interfaces — Produces:** `_upg_swap_node_binary <src_bin> <node_root>` (same-dir temp + atomic `mv`, executable). `_upg_t0_apply_argv <old_bin> <profile_path> <outdir>` fills `UPG_T0_ARGV`. `scenario_upgrade_run <outdir> <old_bin> <new_bin> <target_ver> [profile_path]` — `profile_path` is an **absolute** path (host resolves via profile resolver; standalone via `FBT_PROFILE_DIR`), default the production profile's absolute path; T0 builds with `old_bin`.

- [ ] **Step 1: Write the failing test** (real swap, not dry text)
```bash
#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
eval "$(sed -n '/^_upg_swap_node_binary()/,/^}/p' "$SD/../scripts/scenarios/scenario_upgrade.sh")"
eval "$(sed -n '/^_upg_t0_apply_argv()/,/^}/p' "$SD/../scripts/scenarios/scenario_upgrade.sh")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'NEW' > "$tmp/new"; printf 'OLD' > "$tmp/root_fisco"; mkdir -p "$tmp/root"; mv "$tmp/root_fisco" "$tmp/root/fisco-bcos"
_upg_swap_node_binary "$tmp/new" "$tmp/root"
assert_eq "NEW" "$(cat "$tmp/root/fisco-bcos")" "binary replaced with new content"
assert_eq "1" "$([[ -x "$tmp/root/fisco-bcos" ]] && echo 1 || echo 0)" "swapped binary executable"
assert_eq "0" "$(ls "$tmp/root"/.fisco-bcos.* 2>/dev/null | wc -l | tr -d ' ')" "no temp leftover"
_upg_t0_apply_argv "/bin/oldfisco" "/abs/prof.profile" "/out"
assert_contains " ${UPG_T0_ARGV[*]} " " /abs/prof.profile " "T0 uses given absolute profile"
assert_eq "/bin/oldfisco" "$FISCO_BIN_FOR_T0" "T0 baseline binary threaded via env, not argv"
assert_done
```
- [ ] **Step 2: Run — expect FAIL**: `bash tests/upgrade_swap_test.sh`
- [ ] **Step 3: Implement** — add both helpers; replace `cp "$bin" "$root/fisco-bcos"` (line 318) and the T8 rollback swap with `_upg_swap_node_binary`:
```bash
_upg_swap_node_binary() { local src="$1" root="$2" tmp; tmp="$(mktemp "$root/.fisco-bcos.XXXXXX")"; cp "$src" "$tmp"; chmod +x "$tmp"; mv -f "$tmp" "$root/fisco-bcos"; }
_upg_t0_apply_argv() { UPG_T0_ARGV=(-p "$2" -o "$3"); FISCO_BIN_FOR_T0="$1"; }   # T0 exports FISCO_BIN=$1 for apply_profile
```
Add the 5th param to `scenario_upgrade_run` (`local profile_path="${5:-$_UPG_DEFAULT_PROFILE_ABS}"`), have T0 call `FISCO_BIN="$old_bin" bash apply_profile.sh "${UPG_T0_ARGV[@]}"`, and update `_upg_dry` text to include `$old_bin`/`$profile_path`.
- [ ] **Step 4: Run — expect PASS**: `bash tests/upgrade_swap_test.sh && bash tests/scenario_upgrade_test.sh`
- [ ] **Step 5: Commit**
```bash
git add scripts/scenarios/scenario_upgrade.sh tests/upgrade_swap_test.sh
COMMIT_VERIFIED=1 git commit -m "fix(upgrade): atomic swap helper, old_bin T0, absolute profile param (sub0 fix4)"
```

---

### Task 7: Relocatability — `_resolve_engine_script` resolver, repo-root via `FBT_REPO_ROOT`, jsd `JAVA_BIN`, engine.json

**Files:** Modify `scripts/apply_profile.sh`, `scripts/scenarios/scenario_ut.sh`, `scripts/scenarios/scenario_jsd.sh`; Create `engine.json`; Test `tests/relocatable_test.sh` (create). **No file-body duplication** — the sibling scripts stay the single source of truth; install-time copying into `libexec/fbt/scripts/` is sub-project 1's packaging step, noted here, not committed as a fork.

**Interfaces — Produces:** `_resolve_engine_script <name>` → abs path, tried in order `$FBT_ENGINE_SCRIPTS` → self dir → sibling `../../fisco-bcos-testing/scripts`; returns 1 if none. `scenario_ut_find_repo_root` honors `$FBT_REPO_ROOT` first. `scenario_jsd` uses `"${JAVA_BIN:-java}"`.

- [ ] **Step 1: Write the failing test**
```bash
#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
ej="$SD/../engine.json"; assert_eq "0" "$([[ -f "$ej" ]] && echo 0 || echo 1)" "engine.json present"
for k in engine_protocol_version event_schema_version output_schema_version; do assert_contains "$(cat "$ej")" "$k" "engine.json has $k"; done
eval "$(sed -n '/^_resolve_engine_script()/,/^}/p' "$SD/../scripts/apply_profile.sh")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; : > "$tmp/cluster_up.sh"
got="$(FBT_ENGINE_SCRIPTS="$tmp" _SELF_DIR="$SD/../scripts" _resolve_engine_script cluster_up.sh)"
assert_eq "$tmp/cluster_up.sh" "$got" "FBT_ENGINE_SCRIPTS wins"
eval "$(sed -n '/^scenario_ut_find_repo_root()/,/^}/p' "$SD/../scripts/scenarios/scenario_ut.sh")"
assert_eq "/my/repo" "$(FBT_REPO_ROOT=/my/repo scenario_ut_find_repo_root)" "repo root honors FBT_REPO_ROOT"
assert_contains "$(grep -n 'JAVA_BIN' "$SD/../scripts/scenarios/scenario_jsd.sh")" "JAVA_BIN" "jsd honors JAVA_BIN"
assert_done
```
- [ ] **Step 2: Run — expect FAIL**: `bash tests/relocatable_test.sh`
- [ ] **Step 3: Implement**
Create `engine.json`:
```json
{ "engine_protocol_version": "1.0.0", "event_schema_version": "1.0.0", "output_schema_version": "1.0.0", "capabilities": ["gate","cluster","case","fuzz","upgrade","ut"] }
```
In `apply_profile.sh` add `_SELF_DIR="${_SELF_DIR:-$SCRIPT_DIR}"` and:
```bash
_resolve_engine_script() { local n="$1" c; for c in "${FBT_ENGINE_SCRIPTS:-}" "$_SELF_DIR" "$_SELF_DIR/../../fisco-bcos-testing/scripts"; do [[ -n "$c" && -f "$c/$n" ]] && { echo "$c/$n"; return 0; }; done; return 1; }
CLUSTER_UP="$(_resolve_engine_script cluster_up.sh)" || { echo "ERROR: cluster_up.sh not found" >&2; exit 1; }
```
In `scenario_ut.sh`: make `scenario_ut_find_repo_root` return `$FBT_REPO_ROOT` when set; resolve `run_ut.sh` via the same order (`FBT_ENGINE_SCRIPTS` → self → sibling). In `scenario_jsd.sh` line 145 area, replace the bare `command -v java` check + later `java` calls with `"${JAVA_BIN:-java}"`.
- [ ] **Step 4: Run — expect PASS**: `bash tests/relocatable_test.sh && bash tests/scenario_ut_test.sh && bash tests/scenario_jsd_test.sh && bash tests/apply_profile_test.sh`
- [ ] **Step 5: Commit**
```bash
git add engine.json scripts/apply_profile.sh scripts/scenarios/scenario_ut.sh scripts/scenarios/scenario_jsd.sh tests/relocatable_test.sh
COMMIT_VERIFIED=1 git commit -m "fix(engine): script resolver, FBT_REPO_ROOT, jsd JAVA_BIN, engine.json 3-version (sub0 fix5)"
```

---

### Task 8: fuzz writes `status=pending` + logical profile (threaded) to writable dir; run_case resolves logical names; update cases + test together

**Files:** Modify `scripts/fuzz_bcos.sh`, `scripts/run_case.sh`; Modify `scenarios/example.case`, `scenarios/fuzz_seed43_idx11.case`, `tests/run_case_test.sh`; Test `tests/fuzz_write_case_test.sh` + `tests/run_case_resolve_test.sh` (create).

**Interfaces — Produces:** `_run_case_resolve_profile <spec> <case_dir>` → abs path (no `/` → `${FBT_PROFILE_DIR:-<repo>/profiles}/<spec>.profile`; has `/` → relative to `case_dir`). `_fuzz_write_case` emits `status = pending` and `profile = <logical>`; case dir defaults to `${FBT_STATE_CASES:-${XDG_STATE_HOME:-$HOME/.local/state}/fbt/cases}`; logical name from `RG_FUZZ_PROFILE_NAME` (driver sets it from the actual profile in use, not a hardcoded default).

- [ ] **Step 1: Write the failing tests**
`tests/run_case_resolve_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
eval "$(sed -n '/^_run_case_resolve_profile()/,/^}/p' "$SD/../scripts/run_case.sh")"
assert_eq "/pdir/production-enterprise.profile" "$(FBT_PROFILE_DIR=/pdir _run_case_resolve_profile production-enterprise /cases)" "logical name -> profile dir"
assert_eq "/cases/sub/x.profile" "$(_run_case_resolve_profile sub/x.profile /cases)" "relative path -> case dir"
assert_done
```
`tests/fuzz_write_case_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SD/assert.sh"
eval "$(sed -n '/^_fuzz_write_case()/,/^}/p' "$SD/../scripts/fuzz_bcos.sh")"
_fuzz_inject_curl_cmd() { echo "curl $1"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
RG_FUZZ_PROFILE_NAME=production-enterprise _fuzz_write_case "$tmp/c.case" "production-enterprise" 0xd 43 11 web3method
b="$(cat "$tmp/c.case")"
assert_contains "$b" "status = pending" "pending"
assert_contains "$b" "profile = production-enterprise" "logical name"
assert_not_contains "$b" "profiles/" "no path prefix"
assert_contains "$(cat "$SD/../scenarios/example.case")" "status = example" "example labeled"
assert_contains "$(cat "$SD/../scenarios/fuzz_seed43_idx11.case")" "status = pending" "fuzz case labeled"
assert_done
```
- [ ] **Step 2: Run — expect FAIL**: `bash tests/run_case_resolve_test.sh; bash tests/fuzz_write_case_test.sh`
- [ ] **Step 3: Implement**
In `run_case.sh` add `_run_case_resolve_profile` and use it: `CASE_PROFILE="$(_run_case_resolve_profile "$CASE_PROFILE" "$(dirname "$CASE_PATH")")"` before the `[[ -f "$CASE_PROFILE" ]]` check.
In `fuzz_bcos.sh`: heredoc gains `status = pending`; call site passes `"${RG_FUZZ_PROFILE_NAME:-production-enterprise}"` (a logical name) and writes into `${FBT_STATE_CASES:-${XDG_STATE_HOME:-$HOME/.local/state}/fbt/cases}` (mkdir -p). Change `scenarios/example.case` to `profile = default-latest` + `status = example`; `scenarios/fuzz_seed43_idx11.case` to `profile = production-enterprise` + `status = pending`. Update `run_case_test.sh:7` to expect the resolved logical profile (the dry-run now echoes the resolved absolute path, or the logical name — match the implementation's dry-run text).
- [ ] **Step 4: Run — expect PASS**: `bash tests/run_case_resolve_test.sh && bash tests/fuzz_write_case_test.sh && bash tests/fuzz_bcos_test.sh && bash tests/run_case_test.sh`
- [ ] **Step 5: Commit**
```bash
git add scripts/fuzz_bcos.sh scripts/run_case.sh scenarios/example.case scenarios/fuzz_seed43_idx11.case tests/run_case_test.sh tests/run_case_resolve_test.sh tests/fuzz_write_case_test.sh
COMMIT_VERIFIED=1 git commit -m "fix(case): logical profile resolution; fuzz status=pending to writable dir; relabel cases (sub0 fix5)"
```

---

## Final verification (after all tasks)

- [ ] `for t in tests/*_test.sh; do echo "== $t =="; bash "$t" || exit 1; done` — every file `ALL PASS`.
- [ ] `bash -n scripts/*.sh scripts/scenarios/*.sh tests/*.sh ../fisco-bcos-testing/scripts/*.sh` — clean.
- [ ] `bash scripts/gate.sh -p profiles/production-enterprise.profile --dry-run` — four families, stateroot discovers at runtime, no `upgrade`.

## Self-Review (plan vs spec + review)

- **Spec coverage:** Fix 1 → T1–T2 (now incl. fuzz + shared runner); Fix 2 → T3–T4; Fix 3 → T5; Fix 4 → T6; Fix 5 → T7–T8; Fix 6 → T3 (`-w`, effective base, readiness probe) + T4 (web3 precedence).
- **Review closure:** #1 rc-before-mapfile + source lib (T2); #2 fuzz wired (T2); #3 spy/pure-fn not stale dry-run (T4); #4 array argv + spaces boundary (T3/T4); #5 readiness probe + patch precedence (T3/T4); #6 `$req` fixed, validator tests known-but-unregistered, stale assertion rewritten (T5); #7 real swap fixture + absolute profile (T6); #8 resolver test, repo-root, jsd JAVA_BIN, run_case resolution + test lockstep, no file-fork (T7–T8). Minors: exact-key awk + IPv6 brackets (T1), sibling bash guard (T3), spec engine.json synced to 3 fields.
- **Testing invariant:** no test asserts only dry-run text that already holds; each drives a pure function or real fixture so Step 2 genuinely fails today.
- **Execution gate:** T3 Step 4 — confirm `build_chain.sh -v`; if absent, builder patches `config.genesis`.
