# R94 — Store known schedule credits before the handler pull

Status: **not started** · Assigned: yes · Optional/further-review: no · Stack on: [#159](https://github.com/BitChillRSK/dca-contracts/pull/159)

## Objective

On three `DcaManager` user paths, stop reloading a packed storage word the call already holds: store the
known deposit credit and the new schedule nonce before the handler pull, hoist the top-up
`purchaseAmount` read ahead of the interest call, and drop the impossible `toUint128()` on withdrawal.
Pin the three read claims under default and `FOUNDRY_PROFILE=deploy`. Record the companion closed
decisions so a later pass does not reopen them.

## Background

Locked 2026-09-27 in the overlooked-optimizations canvas. Contracts are not proxies and have not
deployed, so reordering a store ahead of a call that cannot change its value is safe. R41 already
reverts unless the handler receives the requested deposit amount, so waiting to credit
`tokenBalance` learns nothing — and the credit shares slot 0 with the anchor, pause, period, and
route, so a packed store after the external call reloads that word. The same reload hits
`s_protocolSettings` when `createDcaSchedule` writes the nonce after the pull. `topUpFromInterest`
reads slot 1 for the owner check, calls out for interest, then reads `purchaseAmount` from the same
word again. `_withdrawToken` subtracts an amount already checked against a `uint128` balance, so
`SafeCast.toUint128()` cannot fail.

Expected Rootstock saving is one flat `SLOAD` (200) per deposit, per create, and — when the deploy
profile inlines the owner check — per top-up. Withdrawal is tens of gas of compute on both schedules.
Figures are pinned by this PR's state-diff tests before any production claim.

## Open product decisions

**none.** The implement / closed split was locked 2026-09-27.

## Scope

- [ ] **1. `depositToken`:** load balance and route, compute the new balance, store `tokenBalance`, then
      call the handler with the route in a local. Emit after the call. Source comment states the durable
      reason (known credit; packed store after the call would reload the word). No relaunch ticket ids
      in `src/` comments.
- [ ] **2. `createDcaSchedule`:** assign `s_protocolSettings.scheduleNonce` before `_handlerForDeposit`,
      with no external call between the settings load and that store. Leave `_storeNewSchedule` after the
      pull (fresh writes; the schedule must not exist before tokens arrive). A token callback during the
      pull may observe the nonce one id ahead of the stored schedule; the pull and the nonce store revert
      together.
- [ ] **3. `_withdrawToken`:** keep the balance in a `uint128` and assign the subtraction result
      directly. Keep the comparison against `withdrawalAmount`. Do not change the revert set.
- [ ] **4. `topUpFromInterest`:** read `purchaseAmount` immediately after the owner check and before
      `_checkTokenYieldsInterest` / `getAccruedInterest`. Leave the `tokenBalance` read and its store
      after the interest call (slot 0 is reloaded for that write on purpose).
- [ ] **5. State-diff pins** under default and `FOUNDRY_PROFILE=deploy`: schedule slot 0 reads once on
      deposit; protocol-settings slot reads once on create (load+store, no reload after the pull);
      schedule slot 1 read count on top-up. If the top-up pin shows no read removed under deploy, keep
      the hoist and do not claim the gas.
- [ ] **6. Docs:** this spec, `IMPLEMENTATION_ORDER.md`, `README.md` Status, and closed-decision
      entries for every canvas "Closed" row (cross-link earlier closures; add any new one).

## Out of scope

- [ ] Folding `IdleErc20Handler` into `TokenHandler` (keep the class; see **Closed decisions**).
- [ ] One public exchange-rate scale (keep adapter constant + `TokenLending` immutable; R88).
- [ ] Further collapse of purchase-row schedule slot 0 loads beyond R81 (feeding pause/period/route
      into the write helper risks splitting the store).
- [ ] Joining `isSwapper` and `getTokenHandler` into one OperationsAdmin view.
- [ ] Switching Uniswap path setters to `calldata` (measured slower; R86).
- [ ] Moving `BitChillOwnable` off `FeeHandler`.
- [ ] Any purchase-path edit, ABI / event / error / storage-layout change.
- [ ] Deploy broadcasts or live contract interaction.

## Closed decisions (2026-09-27)

| Item | Decision | Why |
|---|---|---|
| Fold `IdleErc20Handler` into `TokenHandler` | Keep the class | `TokenHandler` parents both idle and lending. Idle sum as the default batch funding would be a rule lending must override (same diagram lie the fee move removed). The short file is where the no-ledger residual risk is stated. Also rejected under [R90](./R90-final-optimization-decisions.md). |
| One public exchange-rate scale | Keep constant + immutable | Adapter constant is a pushed literal; `TokenLending`'s immutable serves both 1e18 and 1e27. R88's public immutable grew every lending leaf. Constructor passes the constant in, so the two names cannot drift. See [R88](./R88-post-r87-structural-cleanups.md). |
| Schedule slot 0 loaded four times per purchase row | Already fixed (R81) | R81 collapsed field reads to one load and the update to one store. One further load remains inside the write helper to preserve pause, period, and route. Feeding those fields in risks splitting the store (5,000 gas/row to save 200). |
| Two OperationsAdmin calls on a single-handler batch | Leave | `isSwapper` then `getTokenHandler` ≈ 950 Rootstock gas once per batch. Joining them needs a view that answers authorization and routing together. See [ROOTSTOCK-GAS-AUDIT.md](./ROOTSTOCK-GAS-AUDIT.md). |
| Uniswap path setters as `calldata` | Leave on `memory` | Measured slower (R86): `setPurchasePath` 43,390 memory vs 43,605 one copy vs 44,581 per-helper copy. Constructor-shared helpers cannot take `calldata`. |
| Move `BitChillOwnable` off `FeeHandler` | Leave | Dex owner setters for the oracle, floor, and path would force the fee setters to move too, and the storage layout would change, for no hot-path gas. |

## Files likely touched

- `src/DcaManager.sol`
- `test/gas/R94DcaManagerStoreBeforePullGas.t.sol` (and a small lending stub if the top-up pin needs one)
- `docs/relaunch/R94-dcamanager-store-before-pull.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`
- `docs/relaunch/ROOTSTOCK-GAS-AUDIT.md` (cross-link / closed-decision note as needed)

## Required tests

Existing deposit, create, withdraw, and top-up suites must pass unchanged (including revert cases where
the handler or the interest check fails and storage rolls back).

State-diff pins:

```text
forge test --match-path test/gas/R94DcaManagerStoreBeforePullGas.t.sol -vv
FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R94DcaManagerStoreBeforePullGas.t.sol -vv
```

Full executable gate before push:

```text
make check
make check-deploy
make fork-sovryn
make fork-tropykus
```

## Success criteria

- [ ] The four `DcaManager` edits match **Scope**; nothing from **Out of scope** ships.
- [ ] Deposit pin: schedule slot 0 is read once under default and deploy.
- [ ] Create pin: protocol-settings slot is read once under default and deploy (no post-pull reload).
- [ ] Top-up pin: slot 1 read count recorded under both profiles; gas claimed only if a read was removed
      under deploy.
- [ ] Withdrawal no longer calls `toUint128()` on the subtraction result; revert set unchanged.
- [ ] Closed-decision table is in this spec and reflected in `IMPLEMENTATION_ORDER.md` /
      `README.md`.
- [ ] No ABI, event, error, or storage-layout change; no purchase-path edit.
- [x] `make check`, `make check-deploy`, `make fork-sovryn`, and `make fork-tropykus` green.
- [ ] README Status points at this PR; next unassigned prompt recorded.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (no invariant change).
- [ ] Tests match **Required tests**; pins run under both profiles.
- [ ] Extra files beyond this list are named in the PR.
- [ ] No unrelated refactors; history is reviewable.
- [ ] No relaunch ticket ids in `src/` comments.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none. No consumer issue.
