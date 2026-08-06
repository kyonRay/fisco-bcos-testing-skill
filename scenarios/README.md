# scenarios/ — regression `.case` fixtures (the flywheel)

This directory holds declarative `.case` files, each a single confirmed-or-tracked failure
replayed deterministically by `scripts/run_case.sh`. It is **not**
`scripts/scenarios/`, which holds the four `scenario_*.sh` gate scenario *families*
(`ut`, `dual_rpc`, `malformed`, `upgrade` — see `scripts/gate.sh`'s `GATE_KNOWN_SCENARIOS`) that
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

INI-like, one `[case]` section, three required keys:

```
[case]
profile = profiles/default-latest.profile
input = console.sh call HelloWorld get
expect_oracle = pass
```

- `profile` — path (relative to the repo root) to a `.profile` file under `profiles/`. This is
  the exact production config the failure was captured under; `run_case.sh` hands it straight to
  `apply_profile.sh` to reproduce that chain locally.
- `input` — the command the exploration layer used to trigger the failure: a console
  invocation, a curl against the Web3 RPC, a crafted transaction submission, or similar. Applied
  verbatim via `bash -c`; `run_case.sh` does not validate or sandbox it.
- `expect_oracle` — the expected result under the gate's three oracles (`scripts/oracle_crash.sh`,
  `scripts/oracle_liveness.sh`, `scripts/oracle_stateroot.sh`; see `scripts/gate.sh`). One of:
  - `pass` — none of the three oracles should trip. This is also how a "the malicious input gets
    safely rejected" case is written: a rejected input trips no oracle, so there is no separate
    `reject` outcome to track.
  - `crash` / `consensus_halt` / `state_mismatch` — the named oracle is expected to trip. This is
    how a still-open defect gets tracked as a fixture: the case is expected to keep failing its
    own assertion until the underlying defect is fixed, at which point it is edited to
    `expect_oracle=pass`.

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

1. **Exploration confirms a failure.** Working in the sibling `fisco-bcos-testing` or
   `fisco-bcos-vuln-hunt` skill (or by hand), a specific input against a specific profile is
   found to trip an oracle — a crash, a consensus halt, or a state-root mismatch — or, in the
   defensive direction, to be safely rejected where it once wasn't.
2. **Distill into a `.case`.** The confirmed profile + input + oracle outcome become a `.case`
   file: `profile=` the exact `.profile` used, `input=` the exact reproducing command,
   `expect_oracle=` what the oracle check should report.
3. **Drop it in `scenarios/`.** The file lives here permanently — it is the durable record of a
   once-confirmed failure (or a once-fixed one still worth re-checking).
4. **The gate re-runs it every round.** Every fixture accumulated here is meant to be swept by
   future gate rounds (today: run each with `run_case.sh` directly; wiring a `.case` sweep into
   `gate.sh` itself is a natural next step, not yet done), so a regression that was fixed once
   cannot silently come back, and a still-open defect stays visible round over round instead of
   being re-discovered from scratch.

## `example.case`

`scenarios/example.case` is a fixture demonstrating the format, not a captured production
incident — it targets the `default-latest` archetype profile (no real chain data) with a
read-only console call and `expect_oracle=pass`, the common case: confirm a benign input against
a reproduced profile trips nothing.
