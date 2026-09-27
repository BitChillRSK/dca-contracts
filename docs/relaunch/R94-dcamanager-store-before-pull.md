# R94 — Store known schedule credits before the handler pull

Status: **implemented** · GitHub [#160](https://github.com/BitChillRSK/dca-contracts/pull/160) · Assigned: yes · Optional/further-review: no · Stack on: [#159](https://github.com/BitChillRSK/dca-contracts/pull/159)

## Objective

Store `createDcaSchedule`'s new schedule nonce before the handler pull, and drop the impossible
`toUint128()` on withdrawal. Pin the create settings-read under default and `FOUNDRY_PROFILE=deploy`
(via the existing R89 gas pin). Record the companion closed decisions so a later pass does not reopen
them. Deposit store-before-pull and the top-up `purchaseAmount` hoist were tried and **reverted**
after measurement.

## Background

Locked 2026-09-27 in the overlooked-optimizations canvas. Four code candidates were measured
edit-by-edit under both profiles (`deploy` / `via_ir` ships): early create nonce store, deposit
store-before-pull, top-up `purchaseAmount` hoist, and withdrawal downcast drop.

## Open product decisions

**none.**

## Scope

- [x] **`createDcaSchedule`:** assign `s_protocolSettings.scheduleNonce` before `_handlerForDeposit`,
      with no external call between the settings load and that store. Leave `_storeNewSchedule` after the
      pull.
- [x] **`_withdrawToken`:** keep the balance in a `uint128` and assign the subtraction result directly
      (no `SafeCast.toUint128()`). Keep the comparison against `withdrawalAmount`.
- [x] **`depositToken` store-before-pull — reverted.** No saving under shipping `via_ir`.
- [x] **`topUpFromInterest` `purchaseAmount` hoist — reverted.** On deploy: +3 Foundry gas and ~5 B
      bytecode; nothing can change `purchaseAmount` during the interest call anyway.
- [x] **Docs:** closed-decision table for every canvas "Closed" row; pin create via R89 gas test.

## Measured pins (2026-09-27)

Edit-by-edit Foundry gas on PR head vs undoing one edit (auditor scratch worktree). Rootstock for a
removed warm re-read is 200.

| Edit | default | deploy | Verdict |
|---|---:|---:|---|
| `createDcaSchedule` nonce before pull | 99,044 vs 99,043 | 98,870 vs 98,990 (**−120**) | **Keep.** ≈ −200 Rootstock. |
| `_withdrawToken` no `toUint128()` | 9,123 vs 9,250 (**−127**) | 8,803 vs 8,864 (**−61**) | **Keep.** +1 B bytecode. |
| `topUpFromInterest` `purchaseAmount` hoist | 14,277 vs 14,283 (−6) | 13,664 vs 13,661 (**+3**) | **Reverted.** |
| `depositToken` store-before-pull | counted reads only helped legacy | deploy reads unchanged | **Reverted.** |

Create settings-read pin (lives in `test/gas/R89ReviewCandidatesGas.t.sol`): **2** under default, **1**
under deploy.

## Out of scope

- [ ] Folding `IdleErc20Handler` into `TokenHandler` (keep the class; see **Closed decisions**).
- [ ] One public exchange-rate scale (keep adapter constant + `TokenLending` immutable; R88).
- [ ] Further collapse of purchase-row schedule slot 0 loads beyond R81.
- [ ] Joining `isSwapper` and `getTokenHandler` into one OperationsAdmin view.
- [ ] Switching Uniswap path setters to `calldata` (measured slower; R86).
- [ ] Moving `BitChillOwnable` off `FeeHandler`.
- [ ] Any purchase-path edit, ABI / event / error / storage-layout change.
- [ ] Deploy broadcasts or live contract interaction.

## Closed decisions (2026-09-27)

| Item | Decision | Why |
|---|---|---|
| Fold `IdleErc20Handler` into `TokenHandler` | Keep the class | Idle funding as `TokenHandler`'s default would be a rule lending must override. Also rejected under [R90](./R90-final-optimization-decisions.md). |
| One public exchange-rate scale | Keep constant + immutable | See [R88](./R88-post-r87-structural-cleanups.md). |
| Schedule slot 0 loaded four times per purchase row | Already fixed (R81) | Feeding pause/period/route into the write helper risks splitting the store (5,000/row to save 200). |
| Two OperationsAdmin calls on a single-handler batch | Leave | Joining them needs a view that answers authorization and routing together. |
| Uniswap path setters as `calldata` | Leave on `memory` | Measured slower (R86). |
| Move `BitChillOwnable` off `FeeHandler` | Leave | Would force Dex setter moves and a layout change for no hot-path gas. |
| `depositToken` store-before-pull | **Reverted after measure** | No deploy saving. |
| `topUpFromInterest` `purchaseAmount` hoist | **Reverted after measure** | Costs gas/bytes under deploy; interest call cannot change `purchaseAmount`. |

## Files likely touched

- `src/DcaManager.sol`
- `test/gas/R89ReviewCandidatesGas.t.sol` (create settings-read pin: 1 under deploy, 2 under default)
- `docs/relaunch/R94-dcamanager-store-before-pull.md`
- `docs/relaunch/R89-post-r88-review-candidates.md` (footnote that deploy settings reads are now 1)
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`
- `docs/relaunch/ROOTSTOCK-GAS-AUDIT.md`

## Required tests

```text
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC \
  forge test --match-path test/gas/R89ReviewCandidatesGas.t.sol --match-test test_createDcaSchedule -vv
FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC \
  forge test --match-path test/gas/R89ReviewCandidatesGas.t.sol --match-test test_createDcaSchedule -vv
make check
make check-deploy
make fork-sovryn
make fork-tropykus
```

## Success criteria

- [x] Create early nonce store and withdrawal downcast ship; deposit and top-up candidates reverted.
- [x] Create settings pin: 1 under deploy, 2 under default (R89 gas test).
- [x] Closed-decision table reflected in `IMPLEMENTATION_ORDER.md` / `README.md`.
- [x] No ABI, event, error, or storage-layout change; no purchase-path edit.
- [x] Gate green; README Status points at this PR.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Gas claims match **Measured pins** (create + withdraw only).
- [ ] No relaunch ticket ids in `src/` comments.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none.
