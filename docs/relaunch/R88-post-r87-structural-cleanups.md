# R88 — consider the post-R87 structural cleanups

Status: **not started** · Assigned: no · Optional/further-review: yes

## Objective

Decide whether two small structural simplifications found while auditing R87 improve the final handler
hierarchy enough to justify another executable-code PR. Measure and inspect first; do not implement either
candidate until the human sees the evidence and approves it.

## Background

R87 moved `i_stableToken` to the common `StablecoinSource` base and deleted the virtual
`_purchaseToken()` bridge. The follow-up audit found no other redundant cross-branch hook, but it did find
one duplicated scale declaration and one single-use forwarding helper worth a narrow review.

The same audit also saw Foundry's deprecation warning for `vm.snapshot()` / `vm.revertTo()` in the new gas
tests. The repository's current `forge-std` does not expose `snapshotState()` / `revertToState()`, so fixing
that warning today would require a dependency change unrelated to these contracts.

## Open product decisions

Ask after presenting the measurements and artifact comparison:

1. Replace the adapter-local `EXCHANGE_RATE_DECIMALS` constants plus
   `TokenLending.i_exchangeRateDecimals` with one `public immutable EXCHANGE_RATE_DECIMALS` on
   `TokenLending`?
2. Inline LayerBank's single-use `_normalizedIncome()` forwarding helper into `_viewExchangeRate()`?

## Scope

- [ ] Evaluate a shared exchange-rate scale declaration.
  - Keep each protocol scale hardcoded by its adapter (`1e18` for Sovryn/Tropykus, `1e27` for LayerBank);
    do not add a leaf-constructor argument or deployment knob.
  - Preserve every concrete constructor ABI and the existing public
    `EXCHANGE_RATE_DECIMALS()` selector and return value.
  - Compare ABI/method identifiers, metadata-stripped creation/runtime code, deployed size, and gas under
    both default and `deploy` profiles. Explain any artifact change; do not call it a gas improvement
    without a measurement.
  - Keep the protocol-specific reason for each hardcoded scale visible next to the adapter even if the
    getter's declaration moves to the shared base.
- [ ] Evaluate inlining `LayerBankErc20Handler._normalizedIncome()` into `_viewExchangeRate()`.
  - Confirm there is no other caller or override.
  - Compare metadata-stripped creation/runtime code under both profiles; if the compiler already inlines
    it identically, treat this as source readability only.
- [ ] Record one verdict per candidate, including why any rejected source simplification stays.
- [ ] Dependency-gated test cleanup: when a separately justified `forge-std` upgrade makes
  `snapshotState()` / `revertToState()` available, replace `snapshot()` / `revertTo()` in the R87 gas
  tests and rerun them under both profiles. Do not upgrade `forge-std` only to silence this warning.

## Out of scope

- [ ] Reopening any gas candidate R87 rejected or kept.
- [ ] A new common “handler core” around `FeeHandler`, `DcaManagerAccessControl`, and
  `StablecoinSource`; it adds an inheritance layer without deleting state or a virtual seam.
- [ ] Removing the real protocol/route hooks: `_lendingSpender`, `_viewExchangeRate`,
  `_receiptSharesBalance`, `_protocolDeposit`, `_protocolRedeem`, `_batchRetrieveStablecoin`, or
  `_purchaseRbtc`.
- [ ] A standalone `forge-std` bump for deprecated test cheatcodes.

## Files likely touched

Decision record:

- `docs/relaunch/R88-post-r87-structural-cleanups.md`
- `docs/relaunch/README.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`

Only if approved in a later implementation PR:

- `src/TokenLending.sol`
- `src/LendingErc20Handler.sol`
- `src/sovryn/SovrynErc20Handler.sol`
- `src/layerbank/LayerBankErc20Handler.sol`
- `src/tropykus-legacy/TropykusErc20Handler.sol`
- matching unit, deployment, gas, and fork tests that reference `EXCHANGE_RATE_DECIMALS`
- `test/gas/R87FeeTransferredRemovalGas.t.sol` and
  `test/gas/R87IdleLedgerRemovalGas.t.sol` only after a compatible `forge-std` upgrade

## Required tests

- A docs-only decision PR runs no tests.
- Any approved Solidity implementation runs `make check`, `make check-deploy`, `make fork-sovryn`, and
  `make fork-tropykus` before push, plus targeted getter/conversion tests under both profiles.
- A dependency-gated cheatcode rename runs `forge test --match-path 'test/gas/R87*.t.sol' -vv` under
  default and `FOUNDRY_PROFILE=deploy`.

## Success criteria

- [ ] Both structural candidates have before/after artifact evidence and explicit human verdicts.
- [ ] No constructor ABI, getter selector/value, exchange-rate scale, or protocol invariant changes.
- [ ] Any implementation contains only approved candidates.
- [ ] The deprecated cheatcode warning is either removed under an already-approved compatible dependency
  or remains documented without forcing a dependency bump.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` remain unchanged.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No gas claim comes from source shape alone.

## ABI / deploy / cutover impact

- ABI: intended none; prove concrete constructors and `EXCHANGE_RATE_DECIMALS()` are unchanged.
- Scripts: none.
- Cutover: none; no consumer issue unless the evidence reveals an unexpected ABI change, in which case
  do not implement the candidate under this spec.
