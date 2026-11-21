# R121 — Kann audit follow-ups

Status: **assigned** · Assigned: yes · Optional/further-review: no

Branch from `main` (no open relaunch PR).

## Objective

Implement the dispositions given on the Kann audit
([Kann-Audits/BitChill-Audit](https://github.com/Kann-Audits/BitChill-Audit/issues), pinned at
`a229ea3b`): two contract fixes (#1, #10) and the reviewer-document lines promised in the responses to
#3, #4, #5 and #6. Nothing else from the audit changes code.

## Background

- **#1.** `updatePurchaseAmount` refuses an amount above the schedule's current `tokenBalance`. An empty
  schedule therefore cannot be restarted at a smaller size from earned interest: `topUpFromInterest`
  refuses a credit that funds no purchase at the current size, and the size cannot be lowered first
  because `0 < newAmount`. The bound protects nothing. `purchaseAmount > tokenBalance` already arises
  from spend-down and from partial withdrawals, and `_rBtcPurchaseChecksEffects` refuses such a row
  with `DcaManager__ScheduleBalanceNotEnoughForPurchase`. The fix drops the bound from the update only.
  The response declined Kann's proposed special case in `topUpFromInterest`.
- **#10.** `addSwapper` and `revokeSwapper` succeed and emit their event when the flag does not change,
  so a mistyped revocation logs a revocation that did not happen. `setDepositsPaused` already reverts on
  a no-op write.
- **#3, #4, #5, #6.** The responses acknowledged the findings and promised one `AUDIT_GUIDE.md` line
  each, and for #3 a runbook step.

## Open product decisions

**none** — decided by the owner on 2026-11-20 and posted to the audit issues.

## Scope

- [ ] **#1:** `_validatePurchaseAmount(token, purchaseAmount)` keeps only the token-minimum checks.
      `createDcaSchedule` checks `purchaseAmount > depositAmount` itself and keeps
      `DcaManager__PurchaseAmountExceedsBalance`. `updatePurchaseAmount` has no balance bound. The
      `uint96` width check, ownership and the protected-window guard are unchanged.
- [ ] **#1 NatSpec:** `IDcaManager.updatePurchaseAmount` no longer says the amount cannot exceed the
      balance, and says that purchases refuse the schedule until its balance covers one purchase.
      `DcaManager__PurchaseAmountExceedsBalance` names creation.
- [ ] **#10:** `addSwapper` reverts `OperationsAdmin__SwapperUnchanged(swapper, true)` when the account
      is already a swapper and `OperationsAdmin__SwapperIsZeroAddress()` for `address(0)`.
      `revokeSwapper` reverts `OperationsAdmin__SwapperUnchanged(swapper, false)` when the account is not
      a swapper. Remove "Idempotent" from the `SwapperAdded` event and `addSwapper` NatSpec.
- [ ] **`AUDIT_GUIDE.md`:**
  - #4: deposits join purchases and withdrawals in "External illiquidity or pauses can revert…", with a
    full supply cap or a frozen reserve as the example and the idle route as the open alternative.
  - #3: one sentence in "External assumptions": if an issuer removes an idle handler's cash, the loss
    falls on the users who withdraw or are bought for last, including depositors until the pause. Link
    the runbook step.
  - #5: next to the immutable-handler recovery line, the Dex router dependency.
  - #6: next to "A bad row reverts its entire handler batch", that any account can revert a Dex batch by
    moving a thin pool; no funds move.
- [ ] **`docs/relaunch/CUTOVER_RUNBOOK.md`:** a section for issuer action against a handler: pause
      deposits on the pair; unpause only when the handler again holds the pair's principal; otherwise new
      deposits go to a new route.
- [ ] **`PROPERTIES.md`:** SP-53 no longer cites "Idempotent".
- [ ] **Naming (owner request, 2026-11-21):** the private boolean mappings take the `s_is…` form of their
      getters: `s_swappers` → `s_isSwapper`, `s_handlerAssigned` → `s_isHandlerAssigned`
      (`OperationsAdmin`), `s_purchasePathAllowed` → `s_isPurchasePathAllowed` (`PurchaseUniswap`). No
      storage-layout or ABI change; metadata-stripped bytecode is unchanged.

## Out of scope

- [ ] Kann #7, #8, #9, #11: acknowledged or declined without code or document changes.
- [ ] Any change to `topUpFromInterest`, its dust rule, or a partial last purchase.
- [ ] A per-route principal counter, solvency check or monitoring for idle handlers (#3).
- [ ] A replaceable router (#5), a Dex retry (#6), a per-batch `try`/`catch` (#9), catching LayerBank
      error `51` (#11).
- [ ] The gas prototypes under `test/gas/prototype/`; historical specs and audit reports.
- [ ] Consumer code. Consumer work is tracked in the consumer repositories.
- [ ] Moving the consumer pin.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`, `src/PurchaseUniswap.sol` (rename only)
- `test/unit/DcaConfigurationTest.t.sol` (update bound test), a restart-flow test beside the
  `topUpFromInterest` tests, `test/unit/OperationsAdminTest.t.sol`
- `test/fizz/handlers/DcaManagerHandler.sol` (`dcaManager_updatePurchaseAmount_clamped`),
  `test/fizz/Properties.sol` (SP-43 drops the balance bound), `test/fizz/handlers/OperationsAdminHandler.sol`
  (skip no-op swapper writes)
- Tests that add a swapper twice or revoke a non-swapper, found by the failing suites
- `AUDIT_GUIDE.md`, `docs/relaunch/CUTOVER_RUNBOOK.md`, `PROPERTIES.md`, this spec,
  `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

- `forge test --match-path test/unit/DcaConfigurationTest.t.sol`,
  `--match-path test/unit/OperationsAdminTest.t.sol`, `--match-contract FoundryTester`.
- An update above the balance succeeds and emits `PurchaseAmountUpdated`; a purchase of that row then
  reverts `DcaManager__ScheduleBalanceNotEnoughForPurchase`.
- An update below the token minimum still reverts. Creation above the deposit still reverts
  `DcaManager__PurchaseAmountExceedsBalance` (existing edge-case tests unchanged).
- Restart flow on a lending route: an empty schedule with accrued interest lowers its purchase amount,
  then tops up from interest and becomes purchasable. Also with deposits paused on the pair.
- `addSwapper` twice, `revokeSwapper` on a non-swapper, and `addSwapper(address(0))` revert with the new
  errors; a real change still emits its event.
- Gate: `make check`, then `make fork-layerbank`. No fork-specific assertions are added.

## Success criteria

- [ ] Every scope item done; nothing from **Out of scope**.
- [ ] The PR records the consumer confirmations (repository, branch, commit, code location, conclusion).
- [ ] The PR links the consumer issues that carry the new errors and the user-guide wording.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold. The only relaxed rule is the update bound, which no
      invariant states.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.

## ABI / deploy / cutover impact

- ABI: two new errors on `IOperationsAdmin` (`OperationsAdmin__SwapperUnchanged(address,bool)`,
  `OperationsAdmin__SwapperIsZeroAddress()`). No selector, argument or event change.
  `updatePurchaseAmount` accepts amounts it used to refuse.
- Scripts: none, unless a deploy script adds a swapper twice.
- Cutover: monitoring decodes the new errors (`abi.json`). The front end treats an over-balance purchase
  amount as a warning ([front-end#62](https://github.com/BitChillRSK/front-end/issues/62)). The user guide
  states when purchases resume. The bot already skips rows whose balance does not cover one purchase.
