# R82 — transient reentrancy guard

Status: **implemented** · GitHub [#143](https://github.com/BitChillRSK/dca-contracts/pull/143) · Assigned: yes · Optional/further-review: no

## Objective

Replace OpenZeppelin's storage-backed `ReentrancyGuard` in `DcaManager` with `ReentrancyGuardTransient`.
The guarded set and its semantics are unchanged (invariant 6). Each guarded user call drops from about
10,200 Rootstock gas of guard storage to about 300.

## Background

Found by the [Rootstock gas audit of `src/`](./ROOTSTOCK-GAS-AUDIT.md).

OZ 5's `ReentrancyGuard` keeps its flag in an ERC-7201 slot (`0x9b77…5f00`) that stays non-zero
(1 = not entered, 2 = entered). Each guarded call reads the slot and writes 1→2 and then 2→1:

- **Ethereum/Cancun:** one cold `SLOAD` (2,100), a warm dirty write (2,900), then a restore write
  (100) that refunds most of the first. Net cost is about 2,300. That is the "~2,300 gas ≈ 1.4 cents"
  figure `AGENTS.md` invariant 6, `IMPLEMENTATION_ORDER.md` (PR 6), R6, R19, R55, and R69 cite.
- **Rootstock:** `SLOAD` 200 + `RESET` 5,000 + `RESET` 5,000 = **~10,200**. There is no net metering, so
  restoring the original value refunds nothing ([`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md)).

Rootstock has executed `TLOAD`/`TSTORE` since Lovell 7.0.0 (RSKIP-446, mainnet block 7,338,024,
2025-03), at 100 gas each (`GasCost.TLOAD` / `GasCost.TSTORE` in rskj). R23 already records that
Rootstock runs the Cancun transient opcodes, and the repo compiles for `cancun`. OZ 5.7 (the vendored
version) ships `ReentrancyGuardTransient`. Its `ReentrancyGuardReentrantCall()` error has the same
selector, and it has the same `nonReentrant` / `_reentrancyGuardEntered()` surface.

Measured with the audit harness (deploy profile, stub handler; storage and transient access priced
with rskj constants):

| Call | Cancun exec | RSK storage + transient |
|---|---:|---:|
| `updatePurchaseAmount` | 12,200 → 9,393 | 16,200 → **6,300** |
| `setSchedulePaused` | 9,839 → 7,032 | 16,000 → **6,100** |
| `depositToken` | 15,673 → 12,866 | 21,400 → **11,500** |

Foundry will report about −2,800 per call; the Rootstock saving is about **−9,900**. The swap also
removes a one-time cost. OZ's storage guard constructor writes `NOT_ENTERED` into an empty slot, a
`SET` of 20,000 gas at deploy, and the transient guard has no constructor write. That does not affect
the decision. OZ's own `_nonReentrantAfter` comment says restoring the value "triggers a refund
(EIP-2200)". That refund is exactly the one Rootstock does not pay. The twelve guarded
entry points are `createDcaSchedule`, `depositToken`, `updatePurchaseAmount`, `updatePurchasePeriod`,
`setSchedulePaused`, `deleteDcaSchedule`, `withdrawToken`, `withdrawTokenAndInterest`,
`topUpFromInterest`, `withdrawAllAccumulatedInterest`, `withdrawRbtcFromTokenHandler`, and
`withdrawAllAccumulatedRbtc`. The swapper purchase paths are unguarded and unaffected.

## Open product decisions

**none.** Invariant 6 keeps the whole guarded set. This changes what the guard costs, not where it
applies.

## Scope

- [x] `DcaManager` inherits `ReentrancyGuardTransient` instead of `ReentrancyGuard`. No modifier moves,
      and none is added or removed.
- [x] `AGENTS.md` invariant 6: the "refuses before the guard's `SSTORE`" wording becomes the guard's
      transient write, and the gas sentence states the Rootstock cost with and without the transient
      guard.
- [x] `test/utils/OzRevert.sol`: import the error from `ReentrancyGuardTransient` so the helper names the
      guard that ships. The selector is identical.
- [x] Add a regression test showing a guarded call makes no `SSTORE` to the ERC-7201 guard slot (state
      diff) and still reverts on re-entry with `ReentrancyGuardReentrantCall`.
- [x] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Changing which functions are guarded, reordering modifiers, or guarding the swapper paths.
- [ ] Transient storage anywhere else, including caches and handler state.
- [ ] Rewriting the historical ~2,300 figures in R6 / R19 / R55 / R69; the audit record labels them.
- [ ] R81 write coalescing.

## Files likely touched

- `src/DcaManager.sol`
- `test/utils/OzRevert.sol`
- `AGENTS.md`
- a guard regression test under `test/unit/` or `test/gas/`

## Required tests

- Every existing reentrancy test passes unchanged (search `OzRevert` users).
- The new test: one guarded call leaves the `0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00`
  slot untouched, and a re-entrant call into a second guarded function reverts.
- `forge inspect DcaManager storage-layout` is unchanged, because OZ 5's guard never used a sequential
  slot.
- `make check`, `make check-deploy`; fork lanes per `AGENTS.md`. Anvil forks run revm, not rskj, so they
  do not prove Rootstock's `TSTORE` pricing. That rests on the rskj source cited above.

## Success criteria

- [x] Guard semantics unchanged; the same twelve functions are guarded.
- [x] The PR states the saving on both schedules: Foundry measured, Rootstock ≈ 10,200 → ≈ 300 per
      guarded call.
- [x] `AGENTS.md` invariant 6 no longer quotes a Cancun figure as the production cost.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold; invariant 6 is re-worded only as scoped above.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none (same error selector).
- Scripts: none.
- Cutover: this is the first `TSTORE` in shipped bytecode. The human's pre-deploy testnet rehearsal
  should include at least one guarded user call, such as creating a schedule and then updating its
  amount, so Rootstock executes the transient guard before mainnet. No consumer issues.
