# scenarios/ — regression `.case` fixtures (the flywheel)

This directory holds declarative `.case` files, each a single confirmed-or-tracked failure
replayed deterministically by `scripts/run_case.sh`. It is **not**
`scripts/scenarios/`, which holds the four `scenario_*.sh` gate scenario *families*
(`ut`, `dual_rpc`, `malformed`, `jsd` — see `scripts/gate.sh`'s `GATE_KNOWN_SCENARIOS`) that
`gate.sh` runs every round. The two directories serve different layers:

- `scripts/scenarios/*.sh` — general-purpose scenario families, broad by design, exercised on
  every gate round regardless of chain history.
- `scenarios/*.case` (this directory) — narrow, one-fixture-per-known-failure regression
  fixtures, each capturing a single specific input against a single specific profile.

`gate.sh` does not currently read this directory (its scenario-sourcing loop only globs
`scripts/scenarios/*.sh`); replaying a `.case` today means invoking `run_case.sh` directly. See
"The flywheel" below for how a fixture gets here and how it is meant to be swept into gate
rounds later.

## The `.case` format

INI-like, one `[case]` section, three required keys (`profile`/`input`/`expect_oracle`) plus a
`status` field documenting the fixture's place in the flywheel:

```
[case]
status = active
profile = default-latest
input = console.sh call HelloWorld get
expect_oracle = pass
```

- `status` — one of `active`, `pending`, or `example` (see "The flywheel" below for how a fixture
  moves through these):
  - `active` — a confirmed fix. Meant to be swept by the gate every round once a `.case` sweep is
    wired into `gate.sh` itself (not yet done — see "The flywheel" below); today it is replayed
    on demand via `run_case.sh` and is expected to PASS.
  - `pending` — found but not yet fixed. `fuzz_bcos.sh`'s `_fuzz_write_case` auto-distills these
    from a confirmed, bisected oracle trip before the underlying defect is fixed (e.g.
    `fuzz_seed43_idx11.case`); the still-open defect itself lives in `failures.jsonl`. A `pending`
    case is reported, not swept — replaying it via `run_case.sh` is *expected* to FAIL (or
    reproduce the trip outright) until the fix lands, at which point it is re-marked `active`.
  - `example` — a format demonstration, not a captured incident (`example.case` below). Never
    swept; run only by hand.
  `run_case.sh`'s own `[case]` parser does not currently read `status` — like any other
  unrecognized key (see the note on typos below), it is accepted and silently ignored. The field
  is a documented convention for humans and for the future gate sweep to key off of, not (yet)
  something `run_case.sh` itself branches on.
- `profile` — the `.profile` to reproduce, resolved by `run_case.sh`'s
  `_run_case_resolve_profile` in one of three forms, checked in order: an absolute path (used
  as-is); a path containing `/` (resolved relative to the `.case` file's own directory); or — the
  normal, and now the convention shown above — a bare **logical profile name** with no `/` at all
  (e.g. `default-latest`), resolved to `${FBT_PROFILE_DIR:-<repo>/profiles}/<name>.profile`. This
  is the exact production config the failure was captured under; `run_case.sh` hands the resolved
  path straight to `apply_profile.sh` to reproduce that chain locally.
- `input` — the command the exploration layer used to trigger the failure: a console
  invocation, a curl against the Web3 RPC, a crafted transaction submission, or similar. Applied
  verbatim via `bash -c`, with its exit status captured (never allowed to abort `run_case.sh`
  itself — a nonzero exit is exactly what `expect_oracle=reject` expects); `run_case.sh` does not
  otherwise validate or sandbox it.
- `expect_oracle` — one of `pass` or `reject`. This is a release gate whose job is "confirm no
  exceptions": a crash / consensus-halt / state-mismatch oracle trip (`scripts/oracle_crash.sh`,
  `scripts/oracle_liveness.sh`, `scripts/oracle_stateroot.sh`; see `scripts/gate.sh`) is **always**
  a case FAIL, under either value — there is no `expect_oracle` value under which a crash is an
  expected, passing outcome.
  - `pass` — the input is a valid operation. The case PASSES iff the input applied successfully
    (exit 0) AND none of the three oracles trip.
  - `reject` — the input is malformed/malicious and should be refused. The case PASSES iff the
    input was rejected (nonzero exit) AND the node stayed alive (the crash oracle does not trip)
    — the same false-green guard `scripts/scenarios/scenario_malformed.sh`'s `_mal_verdict` uses
    (`rejected==1 && alive==1`): a node that crashed while "rejecting" is a FAIL, not a clean
    reject.

  `run_case.sh`'s `case_verdict` function is the single place this is decided — see its own
  header comment for the exact logic.

A missing required field, or a bad `expect_oracle` value, is an error (nonzero exit, message
naming the file and the field) — see `run_case.sh`'s field validation, which runs before
`--dry-run` even short-circuits, so a malformed `.case` fails the same way with or without
`--dry-run`. An unrecognized key inside `[case]` (a typo of `profile`/`input`/`expect_oracle`) is
silently ignored rather than flagged, the same convention `scripts/profile_lib.sh` uses for
`.profile` files — the resulting error still names the correct field that ended up unset, just not
the misspelled one that was actually typed.

## Running a case

```bash
scripts/run_case.sh scenarios/example.case            # real run — needs a live chain
scripts/run_case.sh --dry-run scenarios/example.case   # print profile/input/expect_oracle, no chain
```

## The flywheel

A `.case` always pins down the *correct*, post-fix behavior — never a still-open defect. A case
that "expects a crash" would be pointless (the gate would need to keep failing on purpose); the
regression-catch mechanism is the reverse: the case asserts the fixed behavior, and if the defect
ever comes back, the case starts reporting `CASE: FAIL` on its own.

1. **Exploration confirms a fix (or a clean rejection).** Working in the sibling
   `fisco-bcos-testing` or `fisco-bcos-vuln-hunt` skill (or by hand), a specific input against a
   specific profile that once tripped an oracle — a crash, a consensus halt, a state-root
   mismatch — is confirmed fixed: the input now applies cleanly (`pass`), or a malformed/malicious
   input is confirmed to be safely refused without taking the node down (`reject`).
2. **Distill into a `.case`.** The confirmed profile + input + expected outcome become a `.case`
   file: `status=active`, `profile=` the exact (logical) `.profile` name used, `input=` the exact
   reproducing command, `expect_oracle=pass` or `reject` per which of the two the confirmed fix
   landed as. A trip that is bisected but not yet fixed instead gets auto-distilled with
   `status=pending` (see `fuzz_bcos.sh`'s `_fuzz_write_case`) — it records the target post-fix
   behavior up front, and is re-marked `active` once the fix actually lands.
3. **Drop it in `scenarios/`.** The file lives here permanently — it is the durable record of a
   once-broken (or still-broken-but-tracked) input.
4. **The gate re-runs it every round.** Every `active` fixture accumulated here is meant to be
   swept by future gate rounds (today: run each with `run_case.sh` directly; wiring a `.case`
   sweep into `gate.sh` itself is a natural next step, not yet done, and `status` is what that
   sweep will filter on — `active` runs and must pass, `pending` is reported but not swept,
   `example` is never swept), so a regression that was fixed once cannot silently come back — it
   resurfaces as a failing case instead of being re-discovered from scratch.

## `example.case`

`scenarios/example.case` is a fixture demonstrating the format, not a captured production
incident — `status = example` marks it as such. It targets the `default-latest` archetype profile
(no real chain data) with a read-only console call and `expect_oracle=pass`, the common case:
confirm a benign input against a reproduced profile trips nothing.
