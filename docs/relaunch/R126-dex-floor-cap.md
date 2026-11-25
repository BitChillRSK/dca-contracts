# R126 — Fixed lower bound on the Dex oracle floor

Status: **assigned** · Assigned: yes · Optional/further-review: no

Base: stacked on [R125](./R125-kann-docs-and-consistency.md) / [#202](https://github.com/BitChillRSK/dca-contracts/pull/202) while it is open; `main` once the Kann stack merges.

PR: [#203](https://github.com/BitChillRSK/dca-contracts/pull/203).

## Objective

Replace the owner-settable Dex safety check with a constant. The owner can still move the swap-time oracle floor (`amountOutMinimumPercent`, 97% at launch), but never below 95% of the oracle-implied output. That is a bound in code, like the 5% fee cap and the five-block protected window. The safety check's storage word, setter, getter, event, two errors and constructor argument go away.

## Background

- [R56](./R56-dex-oracle-floor-is-safety-check.md) made the floor a band:
  - the live floor (97%) is operations;
  - the safety check (95%) bounds how far one owner call may lower the floor, and is itself owner-settable down to zero.

  So the owner, or a compromised Safe, can remove the floor in two calls that one Safe transaction batches (Kann #22).
- The owner, 2026-11-25: the floor's lower bound was never capped in code, and V1 carried that over. A community question on the RootstockCollective asked whether slippage is capped in code. The owner wants it capped before the next audit.
- The Dex execution-quality policy (`DEX-CAPACITY` in relaunch-control) makes the bot's quote checks the operational bound. The contract floor is the emergency backstop for a missing, stale or hostile caller minimum. That backstop does not need to be widened in operation, so it can be fixed.

## Open product decisions

**none.** The constant is 95%, the current launch safety check. The owner can choose another value before merge.

## Scope

- [ ] `PurchaseUniswap`:
  - `uint256 public constant MIN_AMOUNT_OUT_MINIMUM_PERCENT = 0.95 ether`;
  - the constructor and `setAmountOutMinimumPercent` require `MIN_AMOUNT_OUT_MINIMUM_PERCENT <= amountOutMinimumPercent <= 100%`, with the existing `TooLow` / `TooHigh` errors.
- [ ] Remove:
  - `s_amountOutMinimumSafetyCheck`;
  - `setAmountOutMinimumSafetyCheck` and `getAmountOutMinimumSafetyCheck`;
  - `PurchaseUniswap__AmountOutMinimumSafetyCheckUpdated`;
  - `PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh` and `PurchaseUniswap__AmountOutMinimumSafetyCheckUnchanged`;
  - the `amountOutMinimumSafetyCheck` constructor argument from `PurchaseUniswap` and every Dex leaf, legacy leaves included.
- [ ] Scripts: drop the argument and `DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK`.
- [ ] Tests:
  - change every suite that sets, reads or decodes the safety check;
  - keep the floor's bound coverage, now against the constant;
  - Fizz handlers and properties (GL-23, SP-54 where they name it).
- [ ] Docs:
  - `AUDIT_GUIDE.md`: the launch-configuration table, the governance paragraph and the leaked-key worst case. A floor change can no longer go below 95%; `setMocOracle` still replaces the price source in one call;
  - `PROPERTIES.md`;
  - `CUTOVER_RUNBOOK.md` if it names the safety check;
  - this spec, `IMPLEMENTATION_ORDER.md`, `README.md`.

## Out of scope

- [ ] The floor formula, the oracle, the caller minimum, MoC routes, and the 97% launch floor.
- [ ] A cap on `setMocOracle`, and a stablecoin/USD oracle.
- [ ] Consumer code and pins.

## Files likely touched

- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol`, `src/idle/IdleHandlerDex.sol`, `src/layerbank/LayerBankHandlerDex.sol`, `src/sovryn-legacy/SovrynHandlerDex.sol`, `src/tropykus-legacy/TropykusHandlerDex.sol`
- `script/Constants.sol` and the Dex deploy scripts and helper configs
- Tests under `test/unit/`, `test/ai-generated/`, `test/fizz/`, `test/gas/` that use the safety check
- `AUDIT_GUIDE.md`, `PROPERTIES.md`, docs as above

## Required tests

- The constructor and the setter accept exactly 95% and 100%, and reject 95% minus one wei (`TooLow`) and 100% plus one wei (`TooHigh`).
- `MIN_AMOUNT_OUT_MINIMUM_PERCENT()` returns `0.95 ether`.
- No remaining owner call can lower the floor below 95%.
- The swap-time floor is unchanged at the same settings: purchases and the min-out tests pass unchanged apart from the removed argument.
- `make check`, `make check-deploy`, `make fork-layerbank`, `make fork-dex-path`.

## Success criteria

- [ ] No owner-settable value bounds the floor. The bound is the constant.
- [ ] Every consumer that calls or decodes the removed surface has an issue, or none does and the PR says so.

## Reviewer checklist

- [ ] The swap-time math is unchanged.
- [ ] The storage layout comment matches the new packing.
- [ ] No test lost its invalid-input coverage.

## ABI / deploy / cutover impact

- ABI: the Dex handlers lose one setter, one getter, one event and two errors, and gain the `MIN_AMOUNT_OUT_MINIMUM_PERCENT()` getter. The constructor loses one argument.
- Deploy: scripts change with the constructor. Creation code and addresses change.
- Consumers: an ABI refresh for anything that vendors the Dex handler ABI. No consumer at its assigned head calls the safety-check setter or getter.
