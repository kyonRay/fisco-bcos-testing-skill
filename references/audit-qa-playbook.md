# Audit-QA playbook — drive testing from a 提测 / audit handover doc

Use this when the input is a whole audit handover doc (e.g.
`audit/CertiK_release-3.17.0_提测文档.md`) plus the per-release facts that live alongside it
(`audit/CertiK_FIB_Findings.xlsx`, `audit/FIB_commit_links.md`, `audit/findings/FIB-*.md`). Those
files are **inputs** — read the *current* ones, don't trust any list baked into this skill.

## Inputs to gather first

| Input | Why | How |
|-------|-----|-----|
| the 提测 doc | the case list, bucket tags, priorities, in-scope set | read it |
| FIB → PR → commit | to confirm a fix is actually in the branch under test | `audit/FIB_commit_links.md` / `git log <branch>` |
| `audit/findings/FIB-*.md` | the per-fix description + which UT is the direct evidence | read the relevant ones |
| the branch under test | so you test what's merged, not what's planned | `git log --oneline <branch> \| grep '(#<PR>)'` |

## Procedure

1. **Confirm scope.** From the doc's in-scope / out-of-scope sections, list the FIBs to test. Drop
   "暂不修复 / won't-fix / 误报" ones. For any "PR still OPEN" item, verify it actually merged into the
   test branch before testing it (`git log <branch> | grep '#<PR>'`); if not, mark it deferred.

2. **Reuse the doc's bucket tags.** A good handover doc already tags each case A/B/C. Trust them but
   spot-check with the reachability model (SKILL.md Step 2) — especially that no hash-forgery case is
   mistagged as RPC-reachable (the EthEndpoint overwrite trap).

3. **Execute per bucket** (SKILL.md Step 4): Bucket A via `rpc-paths.md`, Bucket B via
   `byte-tampering.md`, Bucket C via `p2p-injection.md` (injector or `run_ut.sh`).

4. **Apply the false-green guards** (SKILL.md Step 5) to every negative case: positive control + node
   alive. The doc's per-group "正向回归" requirement *is* the positive control — run it.

5. **Fill the evidence matrix** (SKILL.md Step 6), one row per case, with the honest `Evidence`
   column (live black-box vs UT-only).

6. **Run the operational dimensions** (SKILL.md "Operational test dimensions"). A handover doc
   typically has a 灰度升级 section (feature flags + a hardfork like FIB-134) and a 性能 section —
   these are release-wide, not per-fix buckets. For every feature-gated / hardfork FIB in scope, test
   it *through the upgrade procedure* (`version-upgrade.md`): off-state on an un-bumped chain, on-state
   after `setSystemConfigByKey` / version bump, and group-wide-consistency for the hardfork. Test the
   authorization FIBs on a governance chain (`permission-governance.md`). Produce the pre/post perf
   baseline (`stress-and-stability.md`). Fold these into the matrix with the Bucket column reading
   `upgrade` / `governance` / `perf`.

7. **Coverage check.** Every in-scope FIB gets a row. Summarize:
   `live black-box: N | UT-only: M | deferred (PR not merged): K | won't-fix/out: J`. This directly
   answers what the doc's §4 "测试产出物" asks for, and makes the UT-only tail explicit instead of
   hiding it under "tested".

## Output template

```
## release-<X> audit-QA result

Coverage: live black-box <N> · UT-only <M> · deferred <K> · out-of-scope <J>

| Case | FIB / PR | Module | Bucket | Evidence | Result | Notes (reject code / alive / control) |
|------|----------|--------|--------|----------|--------|----------------------------------------|
| ... | ... | ... | A/B/C | live / UT-only | PASS/FAIL/DEFER | ... |

### Defects
- <FIB> : <repro steps> · severity · PR

### Side-evidence-only (Bucket C / internal-concurrency) — see SKILL.md
These were not reached black-box; evidence is the cited UT + the long-stability run (no crash / no
leak / no fork). Direct proof lives in audit/findings/FIB-*.md and each PR's UT.
```

## On the internal-concurrency / lifecycle fixes (UAF, data races, lock granularity)

These can't be black-box triggered at all. Don't fake a black-box pass. Their row is `UT-only`, and
the black-box contribution is the long-stability run from `p2p-injection.md` (legal load + fault
injection + ASan), asserting *absence of negative symptoms*: no crash, no deadlock/stall, no
RSS/fd growth, no stateRoot divergence. State that plainly in the matrix Notes.
