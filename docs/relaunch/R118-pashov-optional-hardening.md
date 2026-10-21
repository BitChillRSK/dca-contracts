# R118 — Pashov optional hardening (L06, L14, L17, L25)

Status: **implemented** · GitHub [#187](https://github.com/BitChillRSK/dca-contracts/pull/187) · Assigned: yes · Optional/further-review: no · Tracks [contracts#185](https://github.com/BitChillRSK/dca-contracts/issues/185)

## Objective

Review the four Pashov leads the owner deferred from R117 against the supported tokens, markets, and
current code, and ship the four small hardening changes the review justifies: store the deposit
credit before the handler call, require lending deposits to consume exactly the deposit, skip the
zero-value principal transfer, and check measured WRBTC against the Uniswap oracle floor. Record each
lead's evidence, dependency assumption, and disposition in the Pashov register.

## Background

[`PASHOV_TRIAGE_DECISIONS.md`](./PASHOV_TRIAGE_DECISIONS.md) files L06, L14, L17, and L25 as
"H — separate later PR". The report demonstrates no current exploit for any of them. This spec
decides whether each defensive change is worth its cost.

Dependency evidence, Rootstock mainnet block 9,344,056 (2026-10-21), read-only `cast` calls:

| Contract | Code | Proxy slots |
|---|---|---|
| DOC | 4,429 B | none |
| USDRIF | 855 B | EIP-1967 implementation set |
| USDT0 | 2,227 B | EIP-1967 implementation and admin set |
| WRBTC | 1,763 B | none |
| SwapRouter02 | 24,497 B | none |
| LayerBank Pool and the three launch aTokens | 1,909 B each | EIP-1967 implementation set |

`transfer(x, 0)` returns `true` on DOC, USDRIF, and USDT0 (`eth_call`). The runbook's
`INITIAL_SWAPPER` is the bot EOA; `OperationsAdmin.addSwapper` accepts any address.

## Lead dispositions

### L06 — `depositToken` stores a balance read before the handler call

- **Premise: confirmed.** `depositToken` computes `newTokenBalance` from the schedule, calls the
  handler, then stores it. A callback during the pull that reached an allowlisted swapper could run
  `batchBuyRbtc` on this schedule (purchase paths are not `nonReentrant`, invariant 6). The store
  would then overwrite that purchase's debit, and the schedule would keep stablecoin the handler
  already spent.
- **Reachability at launch: none.** The report finds no hook on DOC, USDRIF, or USDT0, and the launch
  swapper is an EOA. Both conditions are operational: USDRIF, USDT0, and the LayerBank Pool are
  upgradeable, and the swapper allowlist is not restricted to EOAs.
- **Decision: implement.** Store the credit before the handler call. `depositToken` is the only user
  mutator that writes back a schedule value it read before an external call. `_withdrawToken` and
  `deleteDcaSchedule` write first, `topUpFromInterest` reads the balance after its call, and a
  purchase cannot address a schedule `createDcaSchedule` has not stored yet (`InexistentSchedule`).
  Under `deploy` the reads and writes are unchanged. R94 reverted this order as a gas candidate
  because it saved nothing there, not for a safety reason. A failed handler call still rolls the store back.
- **Event order.** `depositToken` and `_withdrawToken` also emit `DcaManager__TokenBalanceUpdated`
  right after their write, before the handler call. Emitting after the call let a callback purchase
  log the stored balance first and the user call's stale balance last, so an indexer keeping the
  last event per schedule would hold the wrong value. `depositToken` reads `routeIndex` before the
  write, as `_withdrawToken` already did, so via-IR does not reread the schedule slot after the emit.

### L14 — lending deposit does not prove full market consumption

- **Premise: confirmed.** `LendingHandler._depositToken` checks the user pull (TokenHandler) and a
  positive share gain, not how much stablecoin the market took. The market holds an unlimited
  allowance, so it can pull less or more than `depositAmount`.
- **Supported markets consume exactly the deposit.** The new check runs on every fork-lane deposit,
  so `make fork-layerbank` and `make fork-sovryn` verify it against the live LayerBank Pool and the
  retained Sovryn iToken. The LayerBank Pool and aTokens are upgradeable behind an immutable handler.
- **Consequence without a check.** A remainder the market leaves stays in the handler with no path
  out (no owner sweep, by decision), while `DcaManager` credits the schedule the full deposit, so the
  depositing user loses it. An excess pull takes other idle stablecoin, normally none.
- **Decision: implement.** Measure the handler's stablecoin balance around `_protocolDeposit` and
  revert `LendingHandler__DepositConsumptionMismatch(intendedDecrease, balanceBefore, balanceAfter)`
  unless it fell by exactly `depositAmount`. This is the exact-consumption rule invariants 11 and 12
  already apply to redeems and purchases, and it fails closed with the user's funds intact.
- **Cost.** Two `balanceOf` calls on user-paid deposits and creations on lending routes, about 3,400
  Rootstock gas (see **Measured cost**). Returning the post-pull balance from
  `TokenHandler._depositToken` would save one of them but add a return value that only the adapter
  check uses. Declined under the user-paid bar in `AGENTS.md`.

### L17 — zero-valued withdrawal still transfers zero tokens

- **Premise: confirmed.** When a user's shares are worth nothing, `LendingHandler._withdrawToken`
  clamps the request to 0, `_redeemShares` returns 0 without a burn, and `TokenHandler` still calls
  `safeTransfer(user, 0)` and emits `TokenHandler__TokenWithdrawn` for 0. `DcaManager` never asks for
  zero (`WithdrawalAmountMustBeGreaterThanZero`; deletion skips a zero balance), so idle routes cannot
  reach it.
- **Tokens and rollback.** All three launch tokens accept zero transfers today, but USDRIF and USDT0
  are upgradeable. If one began rejecting them, a zero-backed schedule (the L12/L16 state) could not
  be withdrawn or deleted. No funds would be at stake, but the schedule would keep its slot and its row
  would keep reverting batches. Either way the revert is atomic.
- **Decision: implement.** Return 0 before the transfer when nothing was redeemed, as
  `withdrawInterest` already does for zero interest. A zero-value withdrawal then emits
  `LendingHandler__WithdrawalAmountAdjusted(user, requested, 0)` and no `TokenHandler__TokenWithdrawn`.
  `DcaManager` still debits the nominal request (accepted principal policy). Cost: one comparison per
  lending principal withdrawal.

### L25 — measured WRBTC is not checked against the oracle floor

- **Premise: confirmed.** `PurchaseUniswap._purchaseRbtc` passes `max(minRbtcOut, oracle floor)` to
  the router. Afterwards `PurchaseRbtc` compares measured WRBTC only with `minRbtcOut`, so with a zero
  caller minimum the oracle floor rests on the router's own output figure.
- **Trusted-router assumption.** SwapRouter02 and WRBTC are not proxies, and every hop is a
  factory-deployed pool. The router derives its figure from pool balance deltas, so measured output
  equals that figure today, and the report shows no divergence.
- **Decision: implement.** Also require measured WRBTC to reach the oracle floor:
  `PurchaseUniswap__BelowOracleFloor(wrbtcReceived, oracleFloor)`. This applies invariant 1 (measured
  receipts, never an integrator figure) to the floor. Only the oracle floor is compared here, so a
  short output against the caller minimum keeps reverting `PurchaseRbtc__BelowSwapperMinimum`. Cost:
  one comparison per Dex batch, with no storage access, so it is the same on both gas schedules.

## Open product decisions

**none.** `IMPLEMENTATION_ORDER.md` lists no gate for R118.

## Scope

- [x] L06: `DcaManager.depositToken` stores `tokenBalance` before the handler call.
- [x] L14: `LendingHandler._depositToken` requires the protocol deposit to reduce the handler's
      stablecoin balance by exactly `depositAmount`; new error on `ILendingHandler`.
- [x] L17: `LendingHandler._withdrawToken` returns 0 without a transfer when nothing was redeemed.
- [x] L25: `PurchaseUniswap._purchaseRbtc` requires measured WRBTC ≥ the oracle floor; new error on
      `IPurchaseUniswap`.
- [x] State the deposit rule in invariant 11 and the write-back rule in invariant 6 of `AGENTS.md`,
      and the deposit, floor, and write-back facts in `AUDIT_GUIDE.md`.
- [x] Update the four register rows, the work table, and the decision log in
      `PASHOV_TRIAGE_DECISIONS.md`.
- [x] Price the gas changes on both schedules and record them here.
- [x] Consumer follow-up for the two new errors and the zero-withdrawal event change.

## Out of scope

- Other Pashov leads, Sovryn-specific remediation, and the Fizz campaigns.
- The nominal-principal policy: `DcaManager` keeps debiting the requested withdrawal.
- `nonReentrant` on the purchase paths (invariant 6), restricting swappers to EOAs, an owner sweep.
- A deposit check in `TokenHandler`'s idle path: it already requires the measured pull to equal the
  request, and idle handlers make no further external call.
- Editing the published Pashov report or its README recommendations.
- Deploy broadcasts or live contract interaction.

## Files likely touched

- `src/DcaManager.sol`
- `src/LendingHandler.sol`, `src/interfaces/ILendingHandler.sol`
- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol`
- `test/unit/DepositSwapPopReentrancyTest.t.sol`, `test/mocks/MockReentrantStablecoin.sol` (L06
  swapper-callback regressions; the mock gains the `burn` the MoC mock calls and a recipient hook)
- `test/unit/DcaDappTest.t.sol` (the shared deposit helper expects the balance event first)
- `test/mocks/MockLayerBank.sol`, `test/ai-generated/unit/layerbank/LayerBankHandlerTest.t.sol` (L14, L17)
- `test/unit/PurchaseUniswapMinOutTest.t.sol` (L25)
- `AGENTS.md`, `AUDIT_GUIDE.md`, `audits/2026-10-13-Pashov-Skills/README.md` (status sentence only)
- `docs/relaunch/ROOTSTOCK-GAS-AUDIT.md` (the R94 entry that recorded the deposit reorder as reverted)
- `docs/relaunch/R118-pashov-optional-hardening.md`, `docs/relaunch/PASHOV_TRIAGE_DECISIONS.md`,
  `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

- L06: a depositor that is also an allowlisted swapper buys its own schedule from the stablecoin's
  `transferFrom` hook. The schedule ends at `old + deposit − purchase`, the purchase's rBTC is
  credited, and the schedule's balance events are the deposit's then the purchase's. The same
  purchase from a `transfer` hook during a withdrawal payout logs the stored balance last.
- L14: a LayerBank pool that pulls less, or more, than the deposit reverts with the new error; the
  user keeps their stablecoin and receives no shares. A normal deposit still leaves the handler with
  no stablecoin (`test_layerbank_aTokenMinting`).
- L17: a zero-value withdrawal makes no stablecoin `transfer` call, returns 0, and succeeds when the
  token rejects zero transfers (`vm.mockCallRevert`). A positive withdrawal is unchanged.
- L25: a router that enforces the floor on its own figure but delivers less WRBTC reverts with the new
  error when the caller minimum is zero. Output at the floor still succeeds, and a short output
  against a binding caller minimum keeps the existing error.
- Gas: Foundry figures for a lending deposit, a lending withdrawal, and a Dex batch under default and
  `deploy`, before and after, converted to Rootstock with `ROOTSTOCK-GAS-SCHEDULE.md`.
- `make check`, `make check-deploy`, `make fork-sovryn`, `make fork-layerbank`, `make fork-dex-path`.
  The fork lanes exercise the L14 check against live LayerBank and Sovryn deposits.

## Measured cost

A scratch probe, run unchanged on the parent (`51e2b093`) and on this head with the parent's mocks,
measured each call in its own test function and counted storage accesses in a separate one. The
figures are Foundry gas, and storage writes are unchanged on every path.

| Path | Change | Foundry default | Foundry deploy | Extra operations (deploy) | Rootstock (deploy) |
|---|---|---:|---:|---|---:|
| Lending `createDcaSchedule` | L14 | +2,132 | +2,013 | 2 calls into the stablecoin, 2 `SLOAD` | ≈ +3,400 |
| Lending `depositToken` | L06 + L14 | +2,033 | +2,005 | same as create | ≈ +3,400 |
| Lending `withdrawToken` | L17 + event order | +1 | +42 | none | +42 |
| Dex handler batch | L25 | +29 | +30 | none | +30 |

The Rootstock column adds 600 for each repeat call into an already-touched contract (100 → 700)
and 100 for each `SLOAD` (warm 100 → flat 200), per `ROOTSTOCK-GAS-SCHEDULE.md`. Under `deploy`
the L06 reorder leaves the reads unchanged (−8 Foundry against create's delta). Under default it
drops one re-read of the schedule slot.

## Implementation evidence

- Each regression test fails with its change reverted on a copy of this head (four mutants, four
  kills) and passes on the head itself. The L06 test also fails on the parent commit with "the
  purchase debit was lost".
- Existing tests keep their errors: a market that pulls the deposit and mints nothing still reverts
  `LendingHandler__LendingProtocolDepositFailed`, because the mint check runs first.

## Auditor follow-up (2026-10-21)

- [P2] `depositToken` emitted its balance after the handler call. In the L06 callback test the
  purchase logged 100 and the deposit then logged 125, while 100 was stored. `_withdrawToken` had
  the same order. Both now emit right after their write (see **Event order** under L06). The deposit
  callback test now checks event order, and a new withdrawal-payout test covers the second path.
  Both fail on `2c008674`, the last commit before this follow-up. The shared `depositStablecoin`
  helper in `DcaDappTest` expected the old order and now expects the balance event first.

## Final local validation

| Command | Result |
|---|---|
| `make check` | All eight unit lanes pass; all 24 dedicated invariant tests pass. |
| `FOUNDRY_OUT=out-deploy FOUNDRY_CACHE_PATH=cache-deploy make check-deploy` (scratch copy) | Same lanes and counts as `make check`. |
| `make fork-sovryn` | 512 passed, 0 failed, 42 skipped. |
| `make fork-layerbank` | 512 passed, 0 failed, 42 skipped. |
| `make fork-dex-path` | 16 passed, 0 failed, 1 skipped on each lane (at `2c008674`; the follow-up does not touch Dex paths). |
| `SWAP_TYPE=dexSwaps STABLECOIN_TYPE=USDRIF make fork-layerbank` / `fork-none` (not gating, at `2c008674`) | 508 / 507 passed through the live router. The 5 / 2 failures fail identically on the parent at block 9,344,102: three router `Too little received` reverts, a 1-wei allocation assertion, and an assertion that the live fee-collector address holds no USDRIF. |

`make check`, `make check-deploy`, `make fork-sovryn` and `make fork-layerbank` ran on `f008e1f2`, which
includes the auditor follow-up.

## Success criteria

- [x] Each lead has a recorded premise check, dependency assumption, and disposition.
- [x] The four changes ship with regression tests that fail without them.
- [x] Gas deltas are priced on both schedules.
- [x] Gates above pass; the register, guide, and invariants match the code.
- [x] Consumer issues name the new errors and the event change.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold; invariant 6 gains the write-back rule and
      invariant 11 the deposit rule.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: new errors `ILendingHandler.LendingHandler__DepositConsumptionMismatch(uint256,uint256,uint256)`
  and `IPurchaseUniswap.PurchaseUniswap__BelowOracleFloor(uint256,uint256)`. A zero-value lending
  withdrawal no longer emits `TokenHandler__TokenWithdrawn`. No selector, argument, or storage change.
- Scripts: none.
- Cutover: comments on the R117 consumer issues, folded into their ABI regeneration: [bitchill-monitoring#49](https://github.com/BitChillRSK/bitchill-monitoring/issues/49#issuecomment-6316902882) (both
  errors and the event change), [front-end#42](https://github.com/BitChillRSK/front-end/issues/42#issuecomment-6316903528) (the deposit error), [swapper-bot#23](https://github.com/BitChillRSK/swapper-bot/issues/23#issuecomment-6316904324) (the purchase error).
