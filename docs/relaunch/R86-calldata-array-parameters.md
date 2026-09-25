# R86 — `calldata` for external array parameters

Status: **implemented** · Assigned: yes · Optional/further-review: no

## Objective

Every array parameter of an external, non-constructor function in `src/` is `calldata`, not `memory`.
On the purchase path that runs all the way down, so the handler's batch arrays are never copied into
memory. No ABI, event, storage, or behavior change. The same PR records the gas candidates the
2026-09-25 purchase-path review deferred, in the [gas audit](./ROOTSTOCK-GAS-AUDIT.md#deferred-candidates-2026-09-25).

## Background

A review of the purchase path at `068a380` (R79 head) listed seven candidates. The human decided this
one on 2026-09-25 as standard practice for read-only external arguments, whatever the saving. They
asked for it on every eligible function, including the Uniswap path setters, and deferred the other
six.

Only three external functions in `src/` take arrays in `memory`:

- `PurchaseRbtc.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, minRbtcOut)`: the handler side of
  every purchase batch.
- `PurchaseUniswap.setPurchasePathAllowed(intermediateTokens, poolFeeRates, allowed)`: owner-only.
- `PurchaseUniswap.setPurchasePath(intermediateTokens, poolFeeRates)`: owner or swapper.

Every other `memory` in an external signature is either a return value, which must be `memory`, or a
constructor argument, which cannot be `calldata`.

Data location is not part of the ABI. Selectors, the ABI JSON and events are unchanged, so no consumer
is affected.

`DcaManager` already passes its `Batch calldata` into the handler call, so the purchase path starts
from calldata on both sides of the call.

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
- [x] `IPurchaseUniswap` and `PurchaseUniswap`: `setPurchasePathAllowed` and `setPurchasePath` take
      `calldata` arrays.
      - `_encodePurchasePath`, `_setPurchasePath` and `_setPurchasePathAllowed` stay `memory`, because
        the constructor shares them.
      - Each setter now copies its arrays at the call to each helper, where before the ABI decoder
        copied them once. See **Measured**.
- [x] Record the deferred candidates in `ROOTSTOCK-GAS-AUDIT.md`, with the reason each one waits.

## Out of scope

- [ ] Any deferred candidate: the idle ledger, purchase-row event fields, fee sweeping,
      `FeeTransferred`, balance reuse, and `optimizer_runs`.
- [ ] `calldata` variants of the Uniswap path helpers. A second, calldata-only copy of each would
      remove the double copy, but it would duplicate the path encoding the constructor and both setters
      rely on.
- [ ] Constructors and return values, which cannot be `calldata`.

## Files likely touched

- `src/interfaces/IPurchaseRbtc.sol`, `src/PurchaseRbtc.sol`
- `src/FeeHandler.sol`, `src/StablecoinSource.sol`
- `src/idle/IdleErc20Handler.sol`, `src/LendingErc20Handler.sol`
- `src/interfaces/IPurchaseUniswap.sol`, `src/PurchaseUniswap.sol`
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
  Only the 5-row shape was measured, so how this scales with row count is not established.
- **Under legacy codegen the purchase costs more.** Each index into a calldata array is a
  bounds-checked `CALLDATALOAD` with an extra stack slot to carry. The one-time decode copy it
  replaces is cheap for arrays this short. Nothing ships on the default profile.

| Uniswap setter | deploy (`via_ir`, ships) | default (legacy) |
|---|---:|---:|
| `setPurchasePathAllowed(true)` | +1,156 | −175 |
| `setPurchasePath` | +1,191 | −187 |
| `setPurchasePathAllowed(false)` | +1,186 | −175 |

- **Under the shipped profile each setter costs about 1,200 more.** Each array is now copied into
  memory once per helper, twice in all, where before the ABI decoder copied it once.
- These are owner or swapper calls, made when a Dex route changes. The human chose `calldata` here as
  a convention, not for gas.

## Success criteria

- [x] No external, non-constructor function in `src/` takes an array in `memory`.
- [x] The purchase path's arrays stay `calldata` from `DcaManager` through the fee and retrieval
      helpers.
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
