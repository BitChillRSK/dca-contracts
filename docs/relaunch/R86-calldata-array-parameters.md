# R86 — `calldata` for external array parameters

Status: **implemented** · GitHub [#149](https://github.com/BitChillRSK/dca-contracts/pull/149) · Assigned: yes · Optional/further-review: no

## Objective

The handler's purchase batch arrays are `calldata`, not `memory`, all the way down the purchase path,
so they are never copied into memory. The two Uniswap path setters were switched too, then reverted to
`memory` because `calldata` made them dearer (see **Measured**). No ABI, event, storage, or behavior
change. The same PR records the gas candidates the
2026-09-25 purchase-path review deferred, in the [gas audit](./ROOTSTOCK-GAS-AUDIT.md#deferred-candidates-2026-09-25).

## Background

A review of the purchase path at `068a380` (R79 head) listed seven candidates. The human decided this
one on 2026-09-25 as standard practice for read-only external arguments, whatever the saving. They
asked for it on every eligible function, including the Uniswap path setters, and deferred the other
six. On 2026-09-26, after seeing that `calldata` made each setter about 1,200 gas dearer, the human
reverted the setters to `memory`.

Only three external functions in `src/` take arrays in `memory`:

- `PurchaseRbtc.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, minRbtcOut)`: the handler side of
  every purchase batch.
- `PurchaseUniswap.setPurchasePathAllowed(intermediateTokens, poolFeeRates, allowed)`: owner-only.
- `PurchaseUniswap.setPurchasePath(intermediateTokens, poolFeeRates)`: owner or swapper.

Every other `memory` in an external signature is either a return value, which must be `memory`, or a
constructor argument, which cannot be `calldata`.

Data location is not part of the ABI. Selectors, the ABI JSON and events are unchanged, so no consumer
is affected.

`DcaManager` builds `buyers` and `purchaseAmounts` in memory from the schedules, and takes
`scheduleIds` from its `Batch calldata`. Either way the handler call ABI-encodes them, so the handler
receives all three as calldata.

## Open product decisions

**none**. Scope was decided by the human on 2026-09-25.

## Scope

- [x] `IPurchaseRbtc.batchBuyRbtc` and `PurchaseRbtc.batchBuyRbtc`: all three arrays become `calldata`.
- [x] Carry `calldata` down the purchase helpers. Otherwise the first internal call would copy the arrays
      into memory, and the change would save nothing:
      - `FeeHandler._calculateFeeAndNetAmounts` and its two private loops;
      - `StablecoinSource._batchRetrieveStablecoin`;
      - its `IdleErc20Handler` and `LendingErc20Handler` implementations.
- [x] `PurchaseRbtc.batchBuyRbtc`: scope `inputBalanceBefore` / `inputBalanceAfter` to a block.
      - Why: a `calldata` array takes two stack slots (offset and length) where a `memory` array takes
        one. With three of them, the default profile's legacy codegen overflows the stack in the
        allocation loop. `via_ir` does not.
      - The balances are dead once invariant 12's check passes, which is the same reason
        `aggregatedFee` already sits in its own block.
      - The check itself is unchanged.
- [x] Record the deferred candidates in `ROOTSTOCK-GAS-AUDIT.md`, with the reason each one waits.

## Out of scope

- [ ] Any deferred candidate: the idle ledger, purchase-row event fields, fee sweeping,
      `FeeTransferred`, balance reuse, and `optimizer_runs`.
- [ ] `calldata` on `setPurchasePathAllowed` and `setPurchasePath`. Switched, measured, and reverted on
      2026-09-26. Their helpers `_encodePurchasePath`, `_setPurchasePath` and `_setPurchasePathAllowed`
      take `memory` because the constructor shares them, so a `calldata` setter pays a copy at each
      helper call. Copying once at the top of the setter still leaves it dearer than `memory`, and a
      calldata-only copy of each helper would duplicate the path encoding. See **Measured**.
- [ ] Constructors and return values, which cannot be `calldata`.

## Files likely touched

- `src/interfaces/IPurchaseRbtc.sol`, `src/PurchaseRbtc.sol`
- `src/FeeHandler.sol`, `src/StablecoinSource.sol`
- `src/idle/IdleErc20Handler.sol`, `src/LendingErc20Handler.sol`
- Test harnesses that call or override the internal helpers. Internal code cannot create calldata, so:
  - external wrappers take `calldata`;
  - overrides match the new signature;
  - the two invariant mocks pass one-row calldata slices (`buyers[i:i + 1]`);
  - the two fee harnesses that start from a scalar call themselves through an external `calldata`
    function.
- `docs/relaunch/ROOTSTOCK-GAS-AUDIT.md`, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

- `make check` and `make check-deploy`: signatures change on the shared purchase pipeline, so every
  lane is in scope.
- `make fork-sovryn` and `make fork-tropykus` (**Scale the gate to the change** in `AGENTS.md`). No new
  fork assertions.
- Gas before and after, same commit base, both profiles:
  - Purchase: `forge test --match-contract '^RbtcPurchaseTest$' --match-test testBatchPurchasesOneUser --gas-report`,
    reading `DcaManager.batchBuyRbtc` on MoC idle, Sovryn and LayerBank (DOC), and Dex idle and
    LayerBank (USDRIF).
  - Uniswap setters: `testPathPolicyConfigurationGas` on `STABLECOIN_TYPE=USDRIF`, dex, idle.

## Measured

Foundry, 5-row batch, both batch calls in the test (the delta is identical for each). The change
touches only compute, memory and calldata reads, so each figure is also the Rootstock delta
([`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md)). The transaction's calldata bytes do not
change.

| `DcaManager.batchBuyRbtc`, 5 rows | deploy (`via_ir`, ships) | default (legacy) |
|---|---:|---:|
| MoC, idle, DOC | **−986** | +825 |
| MoC, Sovryn, DOC | **−1,184** | +882 |
| MoC, LayerBank, DOC | **−1,184** | +882 |
| Dex, idle, USDRIF | **−849** | +727 |
| Dex, LayerBank, USDRIF | **−1,039** | +784 |

- **The shipped bytecode saves about 850–1,200 gas per 5-row batch**, roughly 0.1% of a batch.
- **Under legacy codegen the purchase costs more.** Each index into a calldata array is a
  bounds-checked `CALLDATALOAD` with an extra stack slot to carry. The one-time decode copy it
  replaces is cheap for arrays this short. Nothing ships on the default profile.

Scaling was measured on 2026-09-26 with a throwaway, uncommitted test. It creates one schedule per row,
five per user, then times a single `DcaManager.batchBuyRbtc` call with `gasleft()` on the `deploy`
profile, at `068a380` and at `70f3a14`. The 5-row column matches the table above to within 1 gas.

| `DcaManager.batchBuyRbtc`, deploy | 1 row | 5 rows | 50 rows |
|---|---:|---:|---:|
| MoC, idle, DOC | −700 | −986 | −4,265 |
| MoC, Sovryn, DOC | −730 | −1,184 | −6,356 |
| Dex, idle, USDRIF | −629 | −848 | −3,369 |

- **The saving grows with the batch** and holds from 1 row up. Past the fixed part it saves roughly
  55–115 gas per row. No shipped purchase shape costs more.

Runtime sizes at `068a380` → `70f3a14` on the `deploy` profile (`forge build --sizes`):

| Contract | Change (bytes) | Margin left |
|---|---:|---:|
| `IdleDocHandlerMoc` | −494 | 18,828 |
| `SovrynDocHandlerMoc` | −530 | 15,903 |
| `LayerBankDocHandlerMoc` | −520 | 15,647 |
| `IdleErc20HandlerDex` | −51 | 14,194 |
| `SovrynErc20HandlerDex` | −63 | 11,589 |
| `LayerBankErc20HandlerDex` | +64 | 11,198 |
| `DcaManager` | 0 | 13,309 |

- **Only `LayerBankErc20HandlerDex` grows**, by 64 bytes. That is a one-time deployment cost of
  about 12,800 gas, with no per-purchase effect.

The Uniswap setters were measured three ways on the same tree, `testPathPolicyConfigurationGas`,
absolute Foundry gas (deploy / default):

| Uniswap setter | `memory` (kept) | `calldata`, one local copy | `calldata`, copy per helper |
|---|---:|---:|---:|
| `setPurchasePathAllowed(true)` | **40,896** / 40,929 | 41,111 / 40,495 | 42,052 / 40,754 |
| `setPurchasePath` | **43,390** / 42,714 | 43,605 / 42,268 | 44,581 / 42,527 |
| `setPurchasePathAllowed(false)` | **16,479** / 16,313 | 16,694 / 15,879 | 17,665 / 16,138 |

- **Under the shipped profile, `memory` is the cheapest.** Passing the `calldata` arrays straight to
  the helpers copies them at each helper call, twice in all, for about 1,200 gas more per setter. One
  local copy at the top of the setter recovers most of that, but is still 215 gas dearer than letting
  the ABI decoder copy them.
- **The setters stay `memory`**, byte-identical to `068a380`. They are owner or swapper calls, made
  when a Dex route changes.

## Success criteria

- [x] The only external, non-constructor functions in `src/` that take an array in `memory` are the
      two Uniswap path setters, where `memory` measured cheapest.
- [x] The purchase path's arrays stay `calldata` from the handler's `batchBuyRbtc` through the fee and
      retrieval helpers.
- [x] ABI and selectors unchanged.
- [x] Measured before and after on both profiles; figures above.
- [x] Deferred candidates recorded in the gas audit.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold:
  - 5: no assembly;
  - 11 and 12: consumption checks unchanged, the purchase one only scoped;
  - 13: accumulated-rBTC helpers untouched.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors.

## ABI / deploy / cutover impact

- ABI: none. Data location does not change selectors, parameter types or events.
- Scripts: none.
- Cutover: none; no consumer issue.
