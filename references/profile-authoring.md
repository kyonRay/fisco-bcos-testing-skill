# Profile authoring — hand-capturing a new `.profile`

`profiles/*.profile` are hand-maintained, not auto-generated (see SKILL.md's 加载 profile section
— there is no drift-detection step). This doc is the capture recipe: how to turn a live production
chain into a `.profile` file `scripts/profile_lib.sh`'s `profile_load` can parse. Read
`profiles/production-enterprise.profile` alongside this — it is the only profile captured from a
real chain (`[meta] source_chain = wbbc-occnode`) and the worked example every field below points
at.

## Format `profile_load` actually parses

INI-like, four fixed section headers (anything else is silently ignored — `profile_load`'s
`case "$section"` only matches these four), `key = value`, `#` comments, blank lines skipped:

```
[meta]                    -> PROFILE_META      (free-form; nothing here is consumed by scripts)
[genesis]                 -> PROFILE_GENESIS   (only compatibility_version is currently wired)
[system_config_replay]    -> PROFILE_REPLAY    (each pair becomes one setSystemConfigByKey call)
[config_ini_override]     -> PROFILE_CONFIG    (each key MUST be "section.key", e.g. executor.enable_dag)
```

## Step 1 — `[meta]`

Free text, not consumed by any script logic — it's provenance for a human reading the profile
later. `production-enterprise.profile` sets:

```
[meta]
source_chain = wbbc-occnode
captured_at = 2026-08-06
binary_version = <生产当前二进制版本,待补充>
```

`source_chain` names the real chain (the archetype profiles use `archetype-<name>` instead —
that's the tell for "hand-curated example," not "captured snapshot"). `binary_version` is
whatever `<binary> --version` reports — leave it a placeholder like the example above rather than
guessing if you don't have it in hand; a placeholder that says so beats a wrong version string.

## Step 2 — `[genesis] compatibility_version`

This is the version the chain was **created** at, not its current live version — get it from the
production node's own `config.genesis` file, not from the console. `build_chain.sh`'s
`generate_genesis_config()` (`tools/BcosAirBuilder/build_chain.sh`) writes it under a `[version]`
section:

```
[version]
    compatibility_version=<x.y.z>
```

Copy that literal value into `[genesis] compatibility_version` in the profile. `apply_profile.sh`
passes it straight to `build_chain.sh -v <value>` (see its dry-run `[1/3] build_chain:` line) to
reproduce the same starting point.

**Extra `[genesis]` keys are metadata only today.** `sm-gov.profile` (`sm_crypto = true`) and
`rpbft-scale.profile` (`consensus_type = rpbft`, `epoch_sealer_num = 4`, `epoch_block_num = 1000`)
show the section accepts arbitrary keys — `profile_load` stores whatever is there — but
`apply_profile.sh` only ever reads `PROFILE_GENESIS[compatibility_version]`; nothing currently
passes these other genesis keys through to `build_chain`. Recording them documents the source
chain's shape; it does not yet make the local reproduction match it on those axes (same category
of gap as the documented `compatibility_version` passthrough gap in SKILL.md's apply_profile 回放
section).

## Step 3 — `[system_config_replay]`

These are flags that were turned on **live**, after genesis, via `setSystemConfigByKey` — not
genesis constants (see SKILL.md's apply_profile 回放: "production feature flags are turned on
live... not creation-time genesis constants"). Capture them from the console:

```
[group0]: /apps> listSystemConfigs
```

This dumps `Config | Value | Enable Block` for every known key. For each row where `Value` is
**not** `null`/`0` (i.e. actually active — see `references/upgrade-path.md` on reading this
table), add one `key = value` line under `[system_config_replay]`. `production-enterprise.profile`
has 13 such pairs, e.g. `feature_balance = 1`, `tx_gas_limit = 3000000`, `web3_chain_id = 60600`.
Only capture what's actually set — do not invent a full flag inventory padded with zeros;
`profile_replay_pairs` only ever emits what's present, and `apply_profile.sh`'s dry-run
explicitly documents "flags absent from the profile are never invented or emitted."

If `compatibility_version` itself was bumped post-genesis (a chain that started at one version and
was later upgraded live), that bump is a `[system_config_replay]` entry too, distinct from the
`[genesis]` value captured in Step 2 — `production-enterprise.profile` has none because that chain
has stayed on its genesis version.

## Step 4 — `[config_ini_override]`

Diff the production node's `config.ini` against a fresh `build_chain`-generated default (same
`compatibility_version`) and record only the lines that differ, as `section.key = value` — the
literal section header and key name from `config.ini`, dot-joined:

```
[config_ini_override]
executor.enable_dag = true
consensus.min_seal_time = 500
txpool.limit = 15000
web3_rpc.enable = true
web3_rpc.listen_port = 8545
rpc.disable_ssl = true
```

`apply_profile.sh` splits each key back into `section`/`key` at the first `.` (`fullkey%%.*` /
`fullkey#*.`) and patches every node's `config.ini` with a perl in-place substitution scoped to
that `[section]` block — see its real-run step `[2/3]`. Get the key names right from the actual
`config.ini` on the node, not from memory: `grep -A3 '^\[executor\]' config.ini` etc.

## Re-capture cadence

There is no automated drift check (SKILL.md: "treat a stale profile as a known, accepted cost").
Re-run this recipe whenever the production chain's config visibly drifts, and bump `captured_at`
when you do — a stale `captured_at` is the only signal a reader has that the snapshot might no
longer match reality.
