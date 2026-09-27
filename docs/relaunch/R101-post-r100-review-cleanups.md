# R101 — Post-R100 review cleanups

Status: **implemented** · GitHub [#167](https://github.com/BitChillRSK/dca-contracts/pull/167) · Assigned: yes · Optional/further-review: no · Stack on: R100 ([#166](https://github.com/BitChillRSK/dca-contracts/pull/166))

## Objective

Record the verdict on every candidate from the 2026-09-27 optimization and code-quality pass over the
R100 tip, and ship the ones that make the code more correct or clearer:

- a registry check that a handler answers to this registry's DcaManager;
- the minimum-purchase check before the create pull;
- a dead top-up guard removed;
- a Tropykus-only error moved off the shared lending interface;
- accurate error names;
- stale or history-bearing NatSpec fixed.

## Background

The pass found no purchase-path gas left: every remaining idea there is already on the closed register
(R79, R80, R81, R86, R87, R89, R90, R94, the R95 review, and the gas audit's closed list). What it
found is small: a hardening gap next to R89 item 7, three pieces of code whose reason had expired,
and names or comments that no longer say what the code does.

The decision bars are the usual ones. A purchase-path saving ships once equivalence is proven. A
user-paid or admin saving ships only if the code gets simpler or clearer. Removing redundant code,
checks, or reads may land at any size once proven. A correctness or clarity change may cost a little
user-paid gas when the gain is real, and the cost is recorded here.

## Open product decisions

**none** — the human asked on 2026-09-27 to implement every reasonable item, including the error rename
(consumer issues instead of a veto) and the `withdrawTokenAndInterest` reorder if it makes the code
more correct. Review showed it does not (see G), and the human dropped it on 2026-09-28.

## Verdicts

| # | Candidate | Verdict | Why |
|---|---|---|---|
| E | `assignTokenHandler` checks the handler's `i_dcaManager()` pins this registry | **Ship** | Same reasoning as R89 item 7's stablecoin check. Add-on handler scripts take `dcaManager` as a parameter, and assignment is a separate owner step. A handler built for another DcaManager, such as the pre-relaunch one, passes every other check and takes its `(token, route)` pair and its address for good, while every deposit through it reverts. It fails closed, so no funds are at risk, but the pair is burned. |
| A | `createDcaSchedule` runs its checks before the pull | **Ship the minimum-purchase half; keep max-schedules after the pull** | The old comment justified both checks by the credited amount. Since the credit became the requested amount, the pull tells them nothing. `_validatePurchaseAmount` now runs with the other argument checks, before the handler lookup, at no gas cost under deploy. Review settled that order (2026-09-28): period and deposit already beat `TokenNotAccepted` / `DepositsPaused`, so the amount check should too. A token with neither a minimum nor a handler now reports `TokenMinPurchaseAmountNotSet` instead of `TokenNotAccepted`; both are true. Moving the max-schedules bound too costs **+450** under deploy on this user-paid path: the push after the handler call has to reread the list's length. So that bound stays next to the push it guards, with a comment that gives this reason instead of the expired one. |
| B | Drop `purchaseAmount == 0 \|\|` in `topUpFromInterest` | **Ship** | Unreachable: every write of `purchaseAmount` meets a non-zero token minimum (`_validatePurchaseAmount`). No test reached it. Same kind of removal as R98. |
| C | Move `LendingHandler__LendingProtocolRedeemFailed` off `ILendingHandler` | **Ship** as `TropykusErc20Handler__LendingProtocolRedeemFailed` on a new `ITropykusErc20Handler` | Only the test-only Tropykus adapter raises it. Every shipped Sovryn and LayerBank handler listed an error it can never raise. `AGENTS.md`: a fact true of one implementation cannot live on a shared interface. R61 deferred this only because R61 was a no-ABI-change PR. Follows the `ILayerBankErc20Handler` precedent. |
| D | Stale or history-bearing NatSpec | **Ship** | `ArraysLengthMismatch` still named batch-purchase arrays, but only withdraw-all raises it since R64. `EmptyBatchPurchaseArrays` named an id/buyer pair that no longer exists and omitted `batchBuyRbtcAcrossHandlers`. `LendingHandler._depositToken` compared itself with "the former adapter-local deltas". `IFeeHandler.FeeHandlerConfig` and the `PurchaseUniswap` constructor described FeeHandler "moving off the funding base" (R92 history). |
| F | `…MustBeGreaterThanMinimum` → `…MustBeAtLeastMinimum` | **Ship** | Both checks accept an amount equal to the minimum, so the old names were wrong. The sibling is already `MinPurchasePeriodMustBeAtLeastOneDay`. Front-end and monitoring get issues rather than a veto. |
| G | `withdrawTokenAndInterest` checks the route class before moving principal | **Closed** (implemented, then dropped after review 2026-09-28) | Not a correctness fix. An idle call already reverts the whole transaction, so no principal stays withdrawn. The reorder changes only which error an over-balance amount reports (`TokenIsNotLent` instead of `WithdrawalAmountExceedsBalance`, both true) and skips a handler call the revert undoes anyway. It cost a second read of schedule slot 0 on every successful lending exit (+109 under deploy, about one 200-gas SLOAD on Rootstock), user-paid, and it added a storage parameter to `_withdrawToken`. Passing `routeIndex` in as well would avoid the read, but makes the helper more complex for the same non-fix. Recorded in the closed register. |
| — | Reuse `_measuredProtocolRedeem`'s stablecoin balance in `TokenHandler._withdrawToken` | **Closed** | About −1,000 Rootstock per lending exit, but user-paid, and it couples the redeem measurement to the transfer measurement across layers, as in R87's rejected balance reuse. Recorded in the closed register. |

## Scope

- [x] E: `IDcaManagerAccessControl` declares `i_dcaManager()`, and `DcaManagerAccessControl` inherits
      its NatSpec. `OperationsAdmin.assignTokenHandler` reverts
      `OperationsAdmin__HandlerDcaManagerMismatch(handler, dcaManager)` unless
      `IDcaManager(handler.i_dcaManager()).i_operationsAdmin() == this`; the check runs after the
      stablecoin check. A handler pinned to a non-DcaManager reverts without data, fails closed, and
      does not consume its address.
- [x] A: `_validatePurchasePeriod` → `_validateDeposit` → `_validatePurchaseAmount` →
      `_handlerForDeposit` → `depositToken`. Max-schedules stays after the pull with its gas reason
      stated.
- [x] B: remove the dead `purchaseAmount == 0` disjunct and its comment sentence.
- [x] C: `ITropykusErc20Handler` holds `TropykusErc20Handler__LendingProtocolRedeemFailed(uint256)`;
      `ILendingHandler` drops `LendingHandler__LendingProtocolRedeemFailed`.
- [x] D: the five NatSpec fixes above.
- [x] F: rename both errors in `IDcaManager`, `DcaManager`, and tests.
- [x] `AGENTS.md`: `IDcaManagerAccessControl` now declares a function, so `ITropykusErc20Handler` joins
      `ILayerBankErc20Handler` as the errors-only example, and joins the list of protocol-specific
      interfaces.

## Out of scope

- [x] The lending-exit double `balanceOf` (closed above).
- [x] G, the `withdrawTokenAndInterest` reorder (closed above).
- [x] Any purchase-path change.
- [x] Moving the max-schedules check before the pull (measured, declined above).

## Files likely touched

- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`
- `src/DcaManagerAccessControl.sol`, `src/interfaces/IDcaManagerAccessControl.sol`
- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `src/LendingHandler.sol`, `src/interfaces/ILendingHandler.sol`
- `src/tropykus-legacy/TropykusErc20Handler.sol`, `src/tropykus-legacy/ITropykusErc20Handler.sol` (new)
- `src/interfaces/IFeeHandler.sol`, `src/PurchaseUniswap.sol`
- `test/unit/TestsHelper.t.sol` and assignment call sites (`OperationsAdminTest`, `DepositsPauseTest`,
  `DcaScheduleTest`), `test/gas/StubPurchaseHandler.sol`, `test/gas/R64BatchGasBenchmark.t.sol`,
  `test/gas/R81PackedSlotWritesGas.t.sol`, `test/gas/R82TransientGuardGas.t.sol`,
  `test/gas/R89ReviewCandidatesGas.t.sol` (stubs report `i_dcaManager`)
- `test/unit/DcaConfigurationTest.t.sol`, `test/ai-generated/unit/DcaManagerEdgeCasesTest.t.sol`
- `AGENTS.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`, `docs/relaunch/README.md`

## Required tests

```text
make check
make check-deploy
make fork-sovryn
make fork-layerbank
FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL={none,sovryn} STABLECOIN_TYPE=DOC \
  forge test --match-path test/gas/R89ReviewCandidatesGas.t.sol -vv
```

Assert:

- `testDeployedHandlerIsAssignableOnlyForItsOwnStablecoinAndRegistry`: the lane's deployed handler is
  refused by a fresh registry for its own stablecoin with `HandlerDcaManagerMismatch`.
- `testHandlerPinnedToANonDcaManagerIsRejected`: fails closed, and the address is not consumed.
- `testCreateRevertsBelowMinPurchaseAmountBeforeTokensMove`: `depositToken` is never called.

Forks: no new fork-specific assertions.

## Measured (deploy profile, Foundry/Cancun schedule, R89 gas pins)

| Call | Lane | Before | After | Δ |
|---|---|---:|---:|---:|
| `createDcaSchedule` | idle | 106,740 | 106,740 | 0 |
| `createDcaSchedule` | Sovryn | 169,792 | 169,792 | 0 |
| `assignTokenHandler` | idle | 50,854 | 52,014 | +1,160 |
| `assignTokenHandler` | Sovryn | 50,900 | 52,104 | +1,204 |

The after figure for `assignTokenHandler` mocks the DcaManager's registry getter to point at the fresh
registry, so the real call costs slightly more. It is one-time and owner-paid: on Rootstock, two more
external calls at a flat 700 each. `withdrawToken` and `withdrawTokenAndInterest` are unchanged
(75,763 / 123,647). Rejected variant: moving the max-schedules bound before the pull as
well measured 107,190 / 170,243 (+450).

## Success criteria

- [x] Every candidate in **Verdicts** is shipped or closed with its reason.
- [x] No purchase-path change, and every invariant in `AGENTS.md` still holds.
- [x] `make check`, `make check-deploy`, `make fork-sovryn`, and `make fork-layerbank` green.
- [x] Consumer issues opened for the renamed and moved errors and the new registry error.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Create runs every argument check (period, deposit, purchase amount) before the handler lookup;
      only max-schedules follows the pull.
- [ ] `src/` comments this PR touches give only a durable reason the code does not say.
- [ ] `withdrawTokenAndInterest` and `_withdrawToken` are unchanged from R100.
- [ ] No relaunch ticket IDs in `src/` comments.

## ABI / deploy / cutover impact

- ABI:
  - `DcaManager__PurchaseAmountMustBeGreaterThanMinimum(address,uint256)` →
    `DcaManager__PurchaseAmountMustBeAtLeastMinimum(address,uint256)`;
  - `DcaManager__PurchasePeriodMustBeGreaterThanMinimum()` → `DcaManager__PurchasePeriodMustBeAtLeastMinimum()`;
  - `LendingHandler__LendingProtocolRedeemFailed(uint256)` is removed from `ILendingHandler`, so shipped
    handlers no longer list it; it reappears as `TropykusErc20Handler__LendingProtocolRedeemFailed(uint256)`
    on the test-only Tropykus adapter;
  - new `OperationsAdmin__HandlerDcaManagerMismatch(address,address)`;
  - `IDcaManagerAccessControl` now declares the existing `i_dcaManager()` getter. No selector changes,
    and ERC-165 `ITokenHandler` / `ILendingHandler` ids are unchanged.
- Scripts: none. Deploy order already assigns handlers built with the new DcaManager.
- Cutover: [front-end#28](https://github.com/BitChillRSK/front-end/issues/28) for the renames;
  [bitchill-monitoring#10](https://github.com/BitChillRSK/bitchill-monitoring/issues/10#issuecomment-5860381130)
  for the renames and the new registry error;
  [bitchill-monitoring#23](https://github.com/BitChillRSK/bitchill-monitoring/issues/23#issuecomment-5860381256)
  for the moved lending error.
