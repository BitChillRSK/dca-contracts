# R18 — Pack DcaDetails storage

Status: **not started** · Assigned: no · Optional/further-review: no

PR 40 of the relaunch stack. Stack on R19 (PR 39). Land after the schedule has its final fields and before new production handlers and R9.

## Objective

Reduce each stored DCA schedule from six-plus slots to three slots with explicit, checked widths that comfortably cover every supported amount, period, timestamp, and route index.

## Background

This is a fresh deployment with no storage migration. `DcaDetails` currently spends one slot on every `uint256`; R19 adds a boolean. Schedule creation, deposit, purchase, and configuration repeatedly read/write these fields, so packing has durable user and bot gas value.

Handler per-user mappings are deliberately excluded: each entry is a single token/share amount, so there is no adjacent field to pack, and narrowing pooled financial accounting creates overflow risk without saving a slot.

## Open product decisions

**none** — pack `DcaDetails` only. Do not narrow handler balances/shares.

## Scope

- [ ] Use checked widths and field order for exactly three slots: `uint128 tokenBalance` + `uint128 purchaseAmount`; `uint32 purchasePeriod` + `uint48 lastPurchaseTimestamp` + `uint32 routeIndex` + `bool paused`; `bytes32 scheduleId`.
- [ ] Keep all external function amount/period/index arguments as `uint256`; use OZ `SafeCast` at the validated storage boundary so overflow has exact revert data.
- [ ] Bound route registration/use consistently to `uint32`; bound periods to `uint32`. Timestamp writes use checked `uint48`. Amounts above `uint128` fail before tokens move or schedule state changes.
- [ ] Update the public `DcaDetails` tuple ordering/types consistently and migrate tests/checked-in consumers.
- [ ] Record `forge inspect DcaManager storageLayout` before/after plus measured create/deposit/purchase/update/delete gas.
- [ ] Prove swap-pop copies every packed field, including `paused` and `scheduleId`.

## Out of scope

- [ ] Packing `LendingErc20Handler.s_shares`, idle balances, accumulated rBTC, fee configuration, or OperationsAdmin mappings.
- [ ] Assembly, unchecked truncation, proxy migration, or changing supported token decimals.
- [ ] New schedule behavior beyond range validation required by the chosen widths.

## Files likely touched

- `src/interfaces/IDcaManager.sol`, `src/DcaManager.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol` for the route bound
- Schedule tests, fuzz/invariant handlers, deployment assertions, and checked-in ABI consumers

## Required tests

Boundary tests at max and max+1 for each narrowed field; pre-transfer rollback for amount overflow; timestamp and route registration bounds; swap-pop fidelity. Inspect layout and gas, then `make check`, `make ci`, and both fork lanes.

## Success criteria

- [ ] One DcaDetails element occupies exactly three storage slots.
- [ ] No unchecked narrowing or financial overflow path exists.
- [ ] Handler financial mappings remain `uint256`.
- [ ] All public tuple consumers are updated before R9.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Chosen maxima are enforced before cash/state mutation.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Layout/gas evidence and boundary tests match **Required tests**.

## ABI / deploy / cutover impact

- ABI: `DcaDetails` component types/order change and include R19's `paused` field; function input widths stay `uint256`.
- Scripts: route constants fit `uint32`; no address/config change.
- Cutover: frontend ABI/types must update. Open or update the frontend issue in this PR.
