# R80 — Remove `DcaManager__CadenceAnchorUpdated`

Status: **implemented** · GitHub [#141](https://github.com/BitChillRSK/dca-contracts/pull/141) ·
Assigned: yes · Optional/further-review: no · Order: stack on the current relaunch tip after R78
(and any docs stacked on it), before R81 and relaunch deployment

## Objective

Remove the purchase-path `DcaManager__CadenceAnchorUpdated` event (declaration and sole emit) so each
successful schedule tick saves ~1,813 gas under the production deploy (`via_ir`) profile. Document why
this is an intentional exception to “emit on every storage write,” and cut over the five consumer
repos that still name the event.

## Background

R75 renamed `LastPurchaseTimestampUpdated` → `CadenceAnchorUpdated` and rebased the field to a UTC-
midnight grid point. The event is emitted once per purchased row from
`DcaManager._rBtcPurchaseChecksEffects`, immediately after `TokenBalanceUpdated`, when
`cadenceAnchor` is written. That is the **only** write site for a non-zero anchor (create stores `0`
with no event).

R78’s deferred gas pass measured the emit at **1,813 gas/row** under `FOUNDRY_PROFILE=deploy` and
**1,946 gas/row** under default. The LOG3 component (`375 + 3 × 375 + 8 × 32 = 1,756`) is profile-
invariant and transfers to Rootstock without a storage-schedule conversion; the remainder is
compiler-generated compute around the emit. See
[R78 R80 survivor](./R78-flat-fee-fast-path.md#r80-survivor-remove-dcamanager__cadenceanchorupdated).

### Product decision (2026-09-23)

**Remove.** The default protocol practice remains “emit when storage changes.” This event is a
deliberate exception:

1. The write is not an independent fact. It only happens on a successful purchase, which already
   emits `PurchaseRbtc__RbtcBought` and `DcaManager__TokenBalanceUpdated`.
2. The new anchor is a pure function of prior `cadenceAnchor`, `purchasePeriod`, and the current UTC
   day start — the same formula in `_rBtcPurchaseChecksEffects`. An indexer that holds the prior
   values can recompute it, or `eth_call` `getDcaSchedule` in the purchase block.
3. The payer is BitChill’s swapper, on every tick forever. User mutators stay fully logged.
4. Contracts are immutable after relaunch; the event cannot be dropped later. Keep
   `TokenBalanceUpdated` and `RbtcBought` — those earn their keep (multi-site balance ledger and the
   purchase record). Do **not** fold the anchor into `TokenBalanceUpdated`; that event’s shape is
   shared across deposit/withdraw/purchase.

## Open product decisions

**none** — remove was answered 2026-09-23 (see Background).

## Scope

- [x] Delete `DcaManager__CadenceAnchorUpdated` from `IDcaManager` and its emit in
      `DcaManager._rBtcPurchaseChecksEffects`. Leave the `cadenceAnchor` storage write and formula
      unchanged.
- [x] Update unit harness expectations: stop declaring/expecting the event in `DcaDappTest`; drop it
      from `EventIndexingTest`’s freeze table.
- [x] Assert post-purchase `cadenceAnchor` via schedule getters where a test previously relied only on
      the event (keep `_expectedCadenceAnchor` / storage assertions).
- [x] Document the decision in this spec, `IMPLEMENTATION_ORDER.md`, and `docs/relaunch/README.md`
      Status. Point `AUDIT_GUIDE.md` at purchase events + getter/recompute instead of this event.
- [x] Open or comment on consumer issues for every repo that must stop indexing or filtering the
      event (`AGENTS.md` Consumer follow-up). Paste URLs in the PR cutover note.

## Out of scope

- [ ] R79 repeated-buyer write coalescing.
- [ ] Changing the cadence formula, `cadenceAnchor` packing, or purchase eligibility.
- [ ] Removing or reshaping `TokenBalanceUpdated`, `RbtcBought`, or any other event.
- [ ] Touching frozen `test/gas/prototype/**` snapshots that still name
      `LastPurchaseTimestampUpdated`.
- [ ] Rewriting historical R9/R10/R75 wording beyond a Status/pointer update that names this decision.
- [ ] `forge fmt` of existing files; live/testnet broadcast.

## Files likely touched

- `src/interfaces/IDcaManager.sol`
- `src/DcaManager.sol`
- `test/unit/DcaDappTest.t.sol`
- `test/unit/EventIndexingTest.t.sol`
- `AUDIT_GUIDE.md`
- `docs/relaunch/R80-remove-cadence-anchor-event.md` (this file)
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`
- `docs/relaunch/R78-flat-fee-fast-path.md` (pointer: survivor → implemented)

## Required tests

```bash
# Targeted: purchase path + event freeze table
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/RbtcPurchaseTest.t.sol
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/EventIndexingTest.t.sol

# Optional gas pin (deploy profile) — median batchBuyRbtc should drop by ~1,813 × rows vs pre-R80 tip
FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn \
  EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/RbtcPurchaseTest.t.sol --gas-report

make check
make fork-sovryn
make fork-tropykus
```

Behaviors:

- Successful purchases still advance `cadenceAnchor` to the expected grid point (existing
  `testCadenceAnchorConsistencyWhenScheduleResumed` and related R75 tests).
- No first-party ABI still declares `DcaManager__CadenceAnchorUpdated`.
- `EventIndexingTest` passes without the removed signature.
- No new fork-specific assertions; forks are the pre-push gate only.

## Success criteria

- [x] Event declaration and emit gone; `cadenceAnchor` write unchanged.
- [x] Tests green under the commands above; `make check` + both forks green before push.
- [x] README Status points at this PR; next unassigned prompt is `Start with R81`.
- [x] Consumer issues opened or updated; URLs in the PR cutover note.
- [x] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (none changed by this PR).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.
- [ ] Consumer cutover URLs present for every affected sibling.

## ABI / deploy / cutover impact

- ABI: **yes** — remove event
  `DcaManager__CadenceAnchorUpdated(address indexed token, uint64 indexed scheduleId, uint256 cadenceAnchor)`.
  No function, error, storage, or other event changes.
- Scripts: none.
- Cutover: consumers that filter or decode this topic0 must drop it. Reconstruct the new anchor from
  prior schedule state + period using the purchase-path formula, or read `getDcaSchedule` after the
  purchase. Prefer `PurchaseRbtc__RbtcBought` as the purchase signal. Regenerate monitoring
  `abi.json`. Implementer opens/updates issues on `front-end`, `swapper-bot`, `bitchill-monitoring`,
  `data-api`, and `metrics-dashboard` as required by `AGENTS.md`.
