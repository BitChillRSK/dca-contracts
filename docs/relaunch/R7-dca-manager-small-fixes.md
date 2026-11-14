# R7 — DcaManager small fixes (R7, R11, R14)

Status: **in progress** (GitHub #45) · Assigned: yes · Optional/further-review: no

## Objective

Fix three small user-facing `DcaManager` gaps: the max-schedules cap must hold after the owner lowers it, a schedule may be funded for exactly one purchase, and users can read accumulated rBTC through `DcaManager` without knowing handler addresses.

## Background

PR 4 bundles these because they are independent, small, and all live on `DcaManager` / `IDcaManager`.

**R7:** `createDcaSchedule` uses `if (numOfSchedules == s_maxSchedulesPerToken)`. That only fires while length grows up to the current cap. If the owner later lowers the cap via `modifyMaxSchedulesPerToken` below a user’s current count, `length == newMax` is false forever and that user can create an unbounded number of extra schedules. Existing tests hide this: they grow from 0 (or one setUp schedule) up to the current max, so `==` happens to fire.

**R11:** `_validatePurchaseAmount` reverts if `purchaseAmount > tokenBalance / 2`, so create / update / `setPurchaseAmount` require current funds to cover two buys. That is a product preference, not a safety invariant. After the first buy of a 2× schedule the remaining balance already equals one purchase. `minPurchaseAmount` (default 25 DOC) stays as the dust/fee floor.

**R14:** rBTC is stored per handler (`PurchaseRbtc.s_usersAccumulatedRbtc`). Users already withdraw through `DcaManager`; they should not have to resolve handler addresses to **read** the same balance. Interest already has this pattern (`getInterestAccrued` / `getMyInterestAccrued`). There is no single protocol-wide number unless the caller names every token × protocol pair.

## Open product decisions

**none**

## Scope

- [x] **R7:** In `createDcaSchedule`, change `if (numOfSchedules == s_maxSchedulesPerToken)` to `>=`. Keep `DcaManager__MaxSchedulesPerTokenReached`.

- [x] **R11:** In `_validatePurchaseAmount`, drop `purchaseAmount > tokenBalance / 2` and `DcaManager__PurchaseAmountMustBeLowerThanHalfOfBalance`. Keep `purchaseAmount >= minPurchaseAmount`. Replace the upper bound with `purchaseAmount > tokenBalance` (exactly one purchase allowed). New error `DcaManager__PurchaseAmountExceedsBalance(address token, uint256 purchaseAmount, uint256 tokenBalance)`. Call sites unchanged: `createDcaSchedule` (balance = `depositAmount`), `setPurchaseAmount` (current schedule balance), `updateDcaSchedule` (balance after optional extra deposit). Update the `setPurchaseAmount` natspec that still says “half of the deposited amount.” Do not allow `purchaseAmount > tokenBalance`.

- [x] **R14:** Add thin view wrappers on `DcaManager` / `IDcaManager`:

  ```solidity
  getAccumulatedRbtcBalance(address user, address token, uint256 lendingProtocolIndex) view returns (uint256)
  getMyAccumulatedRbtcBalance(address token, uint256 lendingProtocolIndex) view returns (uint256)
  ```

  Delegate to `IPurchaseRbtc(address(_handler(token, lendingProtocolIndex))).getAccumulatedRbtcBalance(user)`. Missing handler: same as `_handler` today (`TokenNotAccepted`). Do not return 0 to hide a bad token/protocol pair. Keep `IPurchaseRbtc.getAccumulatedRbtcBalance`. No storage move. No no-arg “all my rBTC” enumerator.

## Out of scope

- [ ] Optional summing getter `getAccumulatedRbtcBalance(user, tokens[], indexes[])`.
- [ ] Fee model, R18 packing, R19 pause, R12/R13/optionals (PR 2 / later PRs).
- [ ] R8 `withdrawStuckRbtc` / `to` parameter.
- [ ] Event reshaping, storage packing, pause.
- [ ] Handler / accounting / SIP-0094 work (R1, R20).
- [ ] `forge fmt` of existing files.
- [ ] Deploy broadcasts or live addresses.
- [ ] `dca-out-contracts`.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `test/unit/DcaConfigurationTest.t.sol`
- `test/ai-generated/unit/GettersTest.t.sol`

Implementer may follow failing tests into `test/ai-generated/unit/DcaManagerEdgeCasesTest.t.sol` and `test/ai-generated/fuzz/Handler.t.sol` (`assume(purchaseAmount <= depositAmount / 2)` → `<= depositAmount`; `MIN_DEPOSIT_AMOUNT` is currently `MIN_PURCHASE_AMOUNT * 2` because of the old two-purchase rule). Extra files belong in the PR write-up.

## Required tests

Commands (targeted first, then done-gate):

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract DcaConfigurationTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract GettersTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract DcaManagerEdgeCasesTest
LENDING_PROTOCOL=tropykus SWAP_TYPE=mocSwaps forge test --match-contract InvariantTest
make check
```

Behaviors to assert:

- Growing from 0 (or one setUp schedule) to max still stops at max (`testMaxSchedulesPerTokenCannotBeExceeded` keeps passing).
- After `modifyMaxSchedulesPerToken` to a value `<` current length, further `createDcaSchedule` reverts; it does not allow more schedules.
- Create with `deposit == purchaseAmount >= min` succeeds; one `buyRbtc` empties the schedule.
- `purchaseAmount` equal to current/deposit balance succeeds on `setPurchaseAmount` / create.
- `purchaseAmount >` current/deposit balance reverts with `DcaManager__PurchaseAmountExceedsBalance`.
- `purchaseAmount < minPurchaseAmount` still reverts.
- No remaining `/ 2` purchase-amount check in `src/`.
- Manager getter equals handler getter for the same user/token/protocol.
- `getMyAccumulatedRbtcBalance` uses `msg.sender`.
- Unknown token/protocol reverts on the single getter (`TokenNotAccepted`).

Fork tests: not required.

## Success criteria

- [x] Growing to max still stops at max; lowering the cap below current length blocks further creates.
- [x] A schedule funded for exactly one purchase can be created and emptied by one buy.
- [x] `purchaseAmount >` balance still reverts; `< min` still reverts; no `/ 2` check remains in `src/`.
- [x] `DcaManager` accumulated-rBTC getters match the handler for the same user/token/protocol; unknown pairs revert; `getMy*` uses `msg.sender`.
- [x] Targeted tests above pass; `make check` passes.
- [x] Protocol invariants in `AGENTS.md` unchanged.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies / failing-test fallout and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: remove `DcaManager__PurchaseAmountMustBeLowerThanHalfOfBalance`. Add `DcaManager__PurchaseAmountExceedsBalance(address token, uint256 purchaseAmount, uint256 tokenBalance)`. Add `getAccumulatedRbtcBalance(address,address,uint256)` and `getMyAccumulatedRbtcBalance(address,uint256)`. No event changes.
- Scripts: none.
- Cutover: frontend may drop the on-chain two-purchase assumption (optional UX warning when deposit `< 2 * purchaseAmount` is out of this repo). Frontend can read accumulated rBTC via `DcaManager` instead of resolving handlers. Do not lower `maxSchedulesPerToken` on the **live** DcaManager until this deployment; the `==` bug is why. Do not include broadcast steps.
