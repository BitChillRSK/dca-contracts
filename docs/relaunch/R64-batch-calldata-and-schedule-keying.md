# R64 — Re-examine the batch calldata shape and how schedules are keyed

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

Measure, and then decide, two coupled design choices on the purchase hot path that have never been
measured: whether `Batch`'s four parallel arrays earn their calldata, and whether
`s_dcaSchedules[user][token][index]` plus the index+id pair is the right way to address a schedule.
This is the last chance to change either before a deployment intended to run for years.

## Background

**The premise this item exists to test is wrong as currently implemented.** The four-array `Batch`
was introduced on the belief that reading schedule fields off-chain and passing them in saves
`SLOAD`s. It does not save any. `_batchBuyRbtc` calls `_rBtcPurchaseChecksEffects`, which loads the
whole `DcaSchedule` from storage regardless (`DcaSchedule memory dcaSchedule = dcaScheduleStorage`)
and then **compares** the loaded values against the passed ones, reverting on mismatch:

```solidity
if (schedulePurchaseAmount != batch.purchaseAmounts[i]) revert DcaManager__PurchaseAmountMismatch(...);
if (scheduleRouteIndex     != batch.routeIndex)         revert DcaManager__RouteIndexMismatch(...);
```

No storage read is skipped, and none can be: `tokenBalance` must be read to be debited, and
`lastPurchaseTimestamp` / `paused` share its slot, so slot 0 is unavoidable. `purchasePeriod` and
`scheduleId` are needed for validation and live in slot 1 alongside `purchaseAmount` and
`routeIndex`, so slot 1 is unavoidable too. Both slots are loaded whatever the calldata says.

`purchaseAmounts` and `routeIndex` are therefore **staleness guards, not gas optimisations**: they
make the batch revert cleanly if a user changed their schedule between the swapper's snapshot and
execution. That is a genuine and probably worth-keeping property — but it is a different property
from the one it was built for, and it should be priced as what it is.

**Storage shape.** `DcaSchedule` packs into exactly 2 slots (64/64 bytes used):

| slot | fields |
|---|---|
| 0 | `tokenBalance` u128 · `lastPurchaseTimestamp` u48 · `paused` bool |
| 1 | `purchaseAmount` u128 · `purchasePeriod` u32 · `routeIndex` u32 · `scheduleId` u64 |

The nested mapping carries `user` and `token` in the key for free, which is what buys that packing.
Per purchase row the current path costs three cold `SLOAD`s: the array length for
`validateScheduleIndex`, plus the two struct slots.

The alternative the audit raised is a flat `mapping(uint64 scheduleId => DcaSchedule)` with the
owner in the struct, so a batch row is just a `uint64` id. That trade is not obviously good and the
spec should not assume it is:

- **Wins.** Calldata drops from four words per row (~880 gas at typical values: buyer address,
  index, id, amount) to one mostly-zero word (~150 gas). The index+id pair collapses to one
  identifier, deleting `validateScheduleIndex`, the id cross-check, and the swap-pop-restores-an-id
  hazard the `ProtocolSettings` NatSpec currently has to warn about.
- **Losses.** A flat mapping must store `user` and `token` (40 bytes) that the nested key gives
  away. Even after dropping `scheduleId` from the struct (it becomes the key, −8 bytes) the struct
  is ~87 bytes, so **3 slots**. Two addresses plus two u128 amounts is already 72 bytes; only
  narrowing both amounts to u96 gets under 64, and that leaves no room for the timestamp, period,
  route index, and pause bit. Three slots is the realistic floor.
- **Net on the hot path** is therefore roughly a wash on storage (3 cold `SLOAD`s either way, since
  the length read disappears) and a clear win on calldata — but only if enumeration is solved
  without adding hot-path cost.
- **Enumeration is the real cost.** `getDcaSchedules(user, token)` and the max-schedules-per-token
  bound both need the per-user array. Keeping it alongside a flat mapping means `createDcaSchedule`
  and `deleteDcaSchedule` write to both structures. Those are cold paths — once per schedule, paid
  by the user — while the batch path runs every day forever and is paid by the protocol operator.
  That asymmetry is the argument for the change; quantify it before accepting it.

## Open product decisions

- [ ] Is the staleness guard worth its calldata? Dropping `purchaseAmounts` from `Batch` saves
      ~240 gas per row and loses the clean `DcaManager__PurchaseAmountMismatch` revert, replacing
      it with a purchase that silently executes at the new amount. Operator-facing call.
- [ ] Is a storage-layout change acceptable at all? A flat mapping is not upgrade-compatible with
      any already-deployed `DcaManager`, so this only lands before the relaunch deploy, never after.

## Scope

This item is **measurement first, implementation second**. Split into two PRs if the measurement
does not clearly favour a change.

- [ ] A gas benchmark of `batchBuyRbtc` at 1, 10, 50, and 200 rows on the current design, split
      into calldata cost, `SLOAD`/`SSTORE` cost, and handler cost. Record it in this file.
- [ ] The same benchmark against a prototype flat-mapping branch, including the `createDcaSchedule`
      and `deleteDcaSchedule` regressions the flat design causes.
- [ ] A decision recorded here, with numbers, even if the decision is "keep the current design".
- [ ] Only then: the implementation, if the numbers justify it.

## Out of scope

- [ ] Any change to the handler interface (`IPurchaseRbtc.batchBuyRbtc` takes buyers, ids, amounts,
      and `minRbtcOut`). If `DcaManager`'s calldata shape changes, the arrays it builds for the
      handler stay as they are.
- [ ] Changing `minRbtcOut` semantics, the oracle floor, or the purchase-period cadence logic.
- [ ] Any other R-item's work.

## Files likely touched

Measurement PR: `test/` only (a new gas benchmark, plus whatever the prototype branch needs).

Implementation PR, if it happens: `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`, and every
test that constructs a `Batch` or calls a schedule mutator by index.

## Required tests

- The benchmark itself, checked in and runnable, so the numbers can be reproduced rather than
  trusted.
- `make check` under **`[profile.default]`** — the measurement basis in
  [`README.md`](./README.md) — and separately under `FOUNDRY_PROFILE=deploy`, since R60 made
  via-IR the profile that ships and the two can disagree on hot-path codegen. Report both.
- If the implementation lands: `make fork-sovryn`, `make fork-tropykus`, `make check-deploy`.

## Success criteria

- [ ] A gas table in this file covering both designs at four batch sizes, under both profiles.
- [ ] The `AGENTS.md` invariant "the schedule index is a position and the id is a creation nonce"
      is either still true or explicitly replaced by a stated alternative.
- [ ] If nothing changes, the `Batch` NatSpec in `IDcaManager` says the cross-check fields are a
      staleness guard and **not** a storage-read saving, so the next reader does not rediscover
      this from scratch.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Every gas number states its profile and its batch size.
- [ ] Any storage-layout change is justified against the cold-path regression it causes, not only
      against the hot-path win.
- [ ] Protocol invariants in `AGENTS.md` still hold, or the spec says which one changed and why.
- [ ] If the decision is to keep the current design, the misleading rationale is corrected in the
      NatSpec anyway — that part ships regardless.

## ABI / deploy / cutover impact

- ABI: potentially large. `Batch` is an ABI struct, and dropping arrays from it changes the
  swapper's encoding. Every schedule mutator takes `(scheduleIndex, scheduleId)` today; collapsing
  to one id changes seven external signatures.
- Scripts: none for the measurement PR.
- Cutover: if the implementation lands, the swapper service and the frontend both change. File
  consumer issues on both sibling repos before merging, per `AGENTS.md`. **This item cannot land
  after the relaunch deploy** — say so in the PR.
