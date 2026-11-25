# R125 — Kann documentation and source consistency

Status: **assigned** · Assigned: yes · Optional/further-review: no

Base: stacked on [R124](./R124-kann-purchase-reentrancy.md) / [#201](https://github.com/BitChillRSK/dca-contracts/pull/201) while it is open; `main` once it merges.

## Objective

Deliver the documentation half of the Kann audit's second-round responses and the `src/` consistency sweep the owner asked for under #19. It is the last of the four PRs. Nothing here changes behavior:

- the NatSpec and comment edits leave the metadata-stripped runtime unchanged;
- one sweep item reorders writes and events in three owner setters, with the same state and logs.

## Background

The owner-approved responses to [Kann](https://github.com/Kann-Audits/BitChill-Audit/issues) #13, #16–#26 promise these corrections. Decisions are from 2026-11-25:

- D3 (#17): amend R66 only; no contract change.
- D6 (#13, #18 I-11, #26): record the configuration and the dependency; no new monitoring.
- D7 (#25): keep blocking both pause directions during a window.
- #16 uses `security@bitchill.app`.
- #18 I-12: NatSpec units only; no ceiling.
- #18 I-07 and #20 item 4: no new events; fix the descriptions.

PRs 1–3 (R122, R123, R124) did the executable work.

## Open product decisions

**none**

## Scope

### `src/` NatSpec and comments

| Item | Where | Change |
|---|---|---|
| #16 | `DcaManager`, `OperationsAdmin`, `IdleDocHandlerMoc`, `IdleHandlerDex`, `LayerBankDocHandlerMoc`, `LayerBankHandlerDex` | Add `@custom:security-contact security@bitchill.app` to each concrete deployed contract |
| #18 I-04 | `LendingHandler._withdrawToken`; `IDcaManager.deleteDcaSchedule`, `DcaScheduleDeleted`; the deletion comment in `DcaManager` | Remove wording that a measured payout can only be smaller. Share rounding can make it larger by a base unit |
| #18 I-05 | `IDcaManager.withdrawAllAccumulatedInterest`, `withdrawAllAccumulatedRbtc` | Each route index must fit `uint32`. One failing pair reverts the whole call; claim the other pairs separately |
| #18 I-07, #20 item 4 | `IDcaManager.DcaManager__TokenBalanceUpdated`, `ITokenHandler.TokenHandler__TokenWithdrawn` | State what each event covers. Creation and deletion carry the balance in their own events. Interest payouts emit `InterestWithdrawn` |
| #18 I-12 | `@param feePurchaseLowerBound` (`IPurchaseFees.setFeeRateParams`), `@param minPurchaseAmount` (`IDcaManager.setTokenMinPurchaseAmount`) | "In the token's base units", with a 6- and an 18-decimal example |
| #19 | event comment in `LendingHandler._batchRetrieveStablecoin` | A clamped row has no event of its own. Its nominal debit is in `TokenBalanceUpdated`, and its funded spending in `RbtcBought.amountSpent` |
| #20 item 2 | `IDcaManager.topUpFromInterest`, the `DcaManager.topUpFromInterest` comment | Replace "preventing dust top-ups" with the rule: the new balance must fund at least one more purchase than the old one |
| #20 item 8 | `s_scheduleIds` NatSpec | The list serves enumeration, the schedule cap, locked principal and share withdrawals. No purchase reads it |
| #20 item 10 | `IPurchaseUniswap` contract NatSpec | The stablecoin must implement `decimals()` and report at most 18 |
| #21 | `OperationsAdmin.setDepositsPaused` `@dev` | A deposit pause does not stop purchases or exits. A window, venue illiquidity, a paused reserve or blocked receipt-token transfers still apply. Drop "can always be withdrawn" |
| #22 | `PurchaseUniswap._validateSlippageSettings`, `IPurchaseUniswap.setAmountOutMinimumSafetyCheck` | Lowering the floor below the safety check takes two calls, which one Safe transaction can batch. Not "two transactions" |
| #24 | `LayerBankDocHandlerMoc` notice | Deposits supply DOC and credit aToken shares |
| #25 | `IDcaManager.setSchedulePaused` | During a protected window both directions revert with `UserMutationsLocked` |

### Source-consistency sweep (#19, owner request)

Findings, listed before editing as the owner asked:

| # | Finding | Action |
|---|---|---|
| S1 | `PurchaseUniswap.setAmountOutMinimumPercent`, `setAmountOutMinimumSafetyCheck` and `setMocOracle` emit before they store. Every other setter stores, then emits | Store, then emit. Same state and logs; bytecode changes on the Dex leaves only |
| S2 | `PurchaseFees` fee loops name the row count `len`; every other row loop uses `purchaseCount` | Rename to `purchaseCount` |
| S3 | `_calculateVariableFee` takes `lowerBound`; its caller and storage use `feePurchaseLowerBound` | Rename the parameter |
| S4 | `LendingHandler._depositToken` names a share count `mintedAmount`, and `_measuredProtocolRedeem` returns `received` while every other measured redemption is `stablecoinReceived` | Rename to `mintedShares` and `stablecoinReceived` |
| S5 | Comparison direction | No change. Reverts compare requested > available and clamps available < requested, as the owner decided under #19. R122 aligned both clamps |
| S6 | The exact-consumption checks use `after > before` (stablecoin) and `after >= before` (shares) | No change. They differ only for a zero amount, and there only the shares check must refuse |
| S7 | Error names that a selector change would fix: the zero-address errors are spelled four ways (`InvalidFeeCollector`, `InvalidOracleAddress`, `SwapperIsZeroAddress`, `ZeroDcaManager`); `PurchaseRbtc__rBtcWithdrawalFailed` and `PurchaseRbtc__rBtcWithdrawn` use `rBtc` where everything else uses `Rbtc`; `InexistentSchedule` | No change. A rename changes the error or event ABI for every consumer at the audit freeze, against the sweep's no-behavior-change rule |
| S8 | `DcaManager.batchBuyRbtcAcrossHandlers` names its loop bound `numBatches`; every other loop bound is `*Count` | Rename to `batchCount` |
| S9 | `LendingHandler._measuredProtocolRedeem` names its pre-balance `stablecoinBalanceBefore`; `_depositToken` names the same measurement `stablecoinBefore` | Rename to `stablecoinBefore` |
| S10 | `PurchaseUniswap._encodePurchasePath` writes `uint256 i = 0`; every other loop leaves the zero implicit | No change. Dropping the zero changes the default-profile bytecode, and so would caching `intermediateTokens.length`, against the sweep's no-behavior-change rule |

### Reviewer documents

- #18 I-08, the five corrections:
  1. `PROPERTIES.md` SP-51: eight guarded calls, both pause directions included.
  2. `AGENTS.md` invariant 8: a purchase also reads slot 1, the owner and purchase amount.
  3. `AUDIT_GUIDE.md`: eight ownable deployments.
  4. `IMPLEMENTATION_ORDER.md`: the fee word is one `uint112` and two `uint16`.
  5. `IMPLEMENTATION_ORDER.md`: the setter is `setFeeCollector`.
- #25 (D7): `AGENTS.md` invariant 10 and `PROPERTIES.md` GL-18 state that both pause directions are blocked during a window.
- #17 (D3):
  - a dated amendment to R66 prohibits automatic window reactivation after a venue failure;
  - `AUDIT_GUIDE.md` states that a swapper key, leaked or following a bad policy, can chain windows, and that only revocation ends it.
- #13: `AUDIT_GUIDE.md` external assumptions. A DOC purchase needs a transaction gas price within MoC's `maxGasPrice`. If Rootstock's minimum gas price rises above it, DOC purchases stop. Exits do not depend on MoC.
- #18 I-02: `AUDIT_GUIDE.md`. Borrowers can remove a lending reserve's cash, even in the same block as a preflight read, which stops lending purchases and cash exits on that route. The share withdrawal and idle routes remain.
- #18 I-03: the runbook verifies each handler's venue addresses against the release configuration. That covers the MoC proxy, the router, WRBTC and the aToken, and their implementations where applicable.
- #18 I-06: runbook precondition 9. The collector must be able to call `DcaManager` and accept native rBTC with empty calldata. A receive-only contract cannot claim.
- #18 I-11: `AUDIT_GUIDE.md`. The lending index is the venue's accounting rate, not proof of backing. A reserve deficit does not lower it, so a loss would surface as failed redemptions or lower measured cash.
- #18 I-12: the runbook has a per-token table of encoded minimums and fee bounds. Verify them before any Safe transaction.
- #26: `AUDIT_GUIDE.md` external assumptions. The Dex floor accepts any price the configured feed reports as valid. Its validity period is the only freshness bound. The runbook records the feed wiring and that period at release.

### Test fix

- `RbtcPurchaseTest.testDepleteHandlerBalance*` asserts exactly zero accrued interest right after deposits. On live LayerBank, half-up mint rounding adds up to half a share per deposit, so a user's summed shares can be worth a base unit or two above principal, and the fork lane fails at some blocks.
  - Allow at most one base unit per deposit there: `SCHEDULES_PER_USER` per user.
  - Every other assertion in those tests stays.

## Out of scope

- [ ] Any executable change beyond S1, any error, event or selector rename, and any new event or check.
- [ ] Historical specs other than R66's amendment, and published third-party audit files under `audits/`.
- [ ] Consumer code and pins.

## Files likely touched

- `src/DcaManager.sol`, `src/OperationsAdmin.sol`, `src/LendingHandler.sol`, `src/PurchaseFees.sol`, `src/PurchaseUniswap.sol`, the four leaves under `src/idle/` and `src/layerbank/`
- `src/interfaces/IDcaManager.sol`, `IPurchaseFees.sol`, `IPurchaseUniswap.sol`, `ITokenHandler.sol`, `IOperationsAdmin.sol` (if its pause wording needs the same correction)
- `AGENTS.md`, `AUDIT_GUIDE.md`, `PROPERTIES.md`, `SECURITY.md`, `docs/relaunch/CUTOVER_RUNBOOK.md`, `docs/relaunch/R66-batch-row-front-running.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`, `docs/relaunch/README.md`, this spec
- `test/unit/RbtcPurchaseTest.t.sol`

## Required tests

- Metadata-stripped runtime and creation code compared with the base for every deployable contract, on both profiles.
  - Identical everywhere except the four Dex leaves (`IdleHandlerDex`, `LayerBankHandlerDex`, and the legacy Sovryn and Tropykus Dex handlers), where only S1 may move it.
  - Prove that by rebuilding the head with S1 reverted.
- `make check`, `make check-deploy` and `make fork-layerbank`, with the three deplete tests passing at a block where they failed before.

## Success criteria

- [ ] Each Kann item above has its correction in the one document that owns the fact; other documents only stop contradicting it.
- [ ] The bytecode comparison holds as stated.
- [ ] Consumer follow-ups opened when the PR opens:
  - a front-end issue to check that Resume, like Pause, is disabled during a protected window (#25);
  - a docs issue, or an update to an existing one, for the event model (#18 I-07, #20 item 4).

## Reviewer checklist

- [ ] No sentence promises more than the code does. In particular, no unconditional exit guarantee replaces the one removed.
- [ ] Each fact lives in one place. No history or rebuttal enters a reviewer document.
- [ ] The sweep's renames are local, private or internal only. No ABI change.

## ABI / deploy / cutover impact

- ABI: none.
- Bytecode: S1 changes the four Dex leaves' runtime. Everything else changes only the metadata hash.
- Scripts: none.
- Consumers: front-end (#25) and docs (event model), as above.
