# R111 — Sovryn iToken type and identifier rename

Status: **assigned** · Assigned: yes · Optional/further-review: no · Stack on: R110
([#176](https://github.com/BitChillRSK/dca-contracts/pull/176))

## Objective

Finish the R104 Sovryn naming pass: rename the vendored loan-token ABI from `IiSusdToken` to
`IiToken`, and rename first-party identifiers / mocks that still say `iSusd` / `Isusd` to `iToken` /
`IToken`. Behavior and bytecode stay the same; DOC's live product ticker may still appear in comments
that name the mainnet address.

## Background

[R104](./R104-identifier-and-natspec-polish.md) renamed `SovrynHandler.i_iSusdToken` → `i_iToken` and
the constructor arg to `iToken`, but left the vendored interface file and type as `IiSusdToken` so it
stayed diffable against an older upstream dump. That left a permanent mismatch: the immutable is an
`IiSusdToken` named `i_iToken`, mocks are `MockIsusdToken`, and tests still say `iSusdToken`. Sovryn's
receipt tokens are iTokens generically; iSUSD is only the DOC instance. Align the type, file, mock,
and locals with `i_aToken` / `i_kToken` parity.

## Open product decisions

**none.**

## Scope

- [ ] Rename `src/sovryn/IiSusdToken.sol` → `IiToken.sol`; interface `IiSusdToken` → `IiToken`.
      Update NatSpec to say iToken (not iSusd) for the generic share surface.
- [ ] Update `SovrynHandler` import/casts and adapter comments that still say iSUSD for the generic
      receipt (keep "iSUSD" only where a comment names the live DOC product / address).
- [ ] Rename `test/mocks/MockIsusdToken.sol` → `MockIToken.sol`; contract `MockIsusdToken` →
      `MockIToken`. Fix the mock ERC-20 name/symbol (was "Tropykus iSUSD") to a generic Mock iToken.
- [ ] Rename remaining first-party identifiers in `src/`, `test/`, `script/` that use `iSusd` /
      `Isusd` / `ISusd` as the BitChill noun (`iSusdToken` → `iToken`, `s_iSusd` → `s_iToken`,
      `bothHalvesISusd` → `bothHalvesIToken`, `test_liveISusd_*` → `test_liveIToken_*`, etc.).
- [ ] Live-address constants that point at DOC's iToken (`I_SUSD` / `ISUSD`) → `I_TOKEN` (comments
      may still say the proxy is iSUSD).
- [ ] Update `foundry.toml` `[fmt].ignore`, `AGENTS.md` vendored-interface list, this folder's
      Status / IMPLEMENTATION_ORDER row. Do **not** rewrite closed historical relaunch specs.

## Out of scope

- [ ] Behavior, gas, packing, purchase-path logic.
- [ ] Renaming `sovrynShareToken` network-config fields (already generic).
- [ ] Rewriting closed R-specs that still say `IiSusdToken` / `iSusd` (R104 rule).
- [ ] Consumer ABI issues (no public selector or event change; `i_iToken()` getter already landed in
      R104).

## Files likely touched

- `src/sovryn/IiSusdToken.sol` → `IiToken.sol`
- `src/sovryn/SovrynHandler.sol`
- `test/mocks/MockIsusdToken.sol` → `MockIToken.sol`
- Call sites under `test/` and `script/` that import or name the old types
- `foundry.toml`, `AGENTS.md`, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

Names-only / no behavior change:

1. `make check`
2. Fork lanes **not** required for this PR (user override; no executable semantics change).

## Success criteria

- [ ] No first-party `IiSusdToken` / `MockIsusdToken` / `iSusdToken` identifier remains in `src/`,
      `test/`, or `script/` (grep clean for those tokens as identifiers; comments may still name the
      live DOC product).
- [ ] `make check` green.
- [ ] Stacked PR on R110; README Status points at this PR; next prompt remains cutover after merge.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants unchanged.
- [ ] No `.gitignore` or unrelated working-tree noise in the PR.
- [ ] Historical relaunch specs left alone.

## ABI / deploy / cutover impact

- ABI: none beyond the already-shipped `i_iToken()` name (R104). The interface rename is compile-time
  only; handlers do not expose `IiSusdToken` in their ABI JSON.
- Scripts: mock type rename in helper configs only.
- Cutover: none.
