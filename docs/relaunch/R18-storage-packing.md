# R18 — Pack DcaSchedule storage

Status: **assigned** · Assigned: yes · Optional/further-review: no

PR 41 of the relaunch stack. Stack on R49 (PR 40, GitHub #90). Land after the schedule has its final name and fields and before new production handlers and R9.

## Objective

Reduce each stored DCA schedule from six-plus slots to three slots with explicit, checked widths that comfortably cover every supported amount, period, timestamp, and route index.

## Background

This is a fresh deployment with no storage migration. `DcaSchedule` (renamed from `DcaDetails` by R49) currently spends one slot on every `uint256`; R19 adds a boolean. Schedule creation, deposit, purchase, and configuration repeatedly read/write these fields, so packing has durable user and bot gas value.

Handler per-user mappings are deliberately excluded: each entry is a single token/share amount, so there is no adjacent field to pack, and narrowing pooled financial accounting creates overflow risk without saving a slot.

## Open product decisions

**none** — pack `DcaSchedule` only. Do not narrow handler balances/shares.

## Scope

- [x] Use checked widths and field order for exactly three slots: `uint128 tokenBalance` + `uint128 purchaseAmount`; `uint32 purchasePeriod` + `uint48 lastPurchaseTimestamp` + `uint32 routeIndex` + `bool paused`; `bytes32 scheduleId`.
- [x] Keep all external function amount/period/index arguments as `uint256`; use OZ `SafeCast` at the validated storage boundary so overflow has exact revert data.
- [x] Bound route registration/use consistently to `uint32`; bound periods to `uint32`. Timestamp writes use checked `uint48`. Amounts above `uint128` fail before tokens move or schedule state changes.
- [x] Update the public `DcaSchedule` tuple ordering/types consistently and migrate tests/checked-in consumers.
- [x] Record `forge inspect DcaManager storageLayout` before/after plus measured create/deposit/purchase/update/delete gas.
- [x] Prove swap-pop copies every packed field, including `paused` and `scheduleId`.

## Out of scope

- [x] Packing `LendingErc20Handler.s_shares`, idle balances, accumulated rBTC, fee configuration, or OperationsAdmin mappings.
- [x] Assembly, unchecked truncation, proxy migration, or changing supported token decimals.
- [x] New schedule behavior beyond range validation required by the chosen widths.

## Files likely touched

- `src/interfaces/IDcaManager.sol`, `src/DcaManager.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol` for the route bound
- Schedule tests, fuzz/invariant handlers, deployment assertions, and checked-in ABI consumers

## Required tests

Boundary tests at max and max+1 for each narrowed field; pre-transfer rollback for amount overflow; timestamp and route registration bounds; swap-pop fidelity. Inspect layout and gas, then `make check`, `make ci`, and both fork lanes.

Targeted: `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract SchedulePackingTest`.

## Success criteria

- [x] One DcaSchedule element occupies exactly three storage slots.
- [x] No unchecked narrowing or financial overflow path exists.
- [x] Handler financial mappings remain `uint256`.
- [x] All public tuple consumers are updated before R9.
- [x] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Chosen maxima are enforced before cash/state mutation.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Layout/gas evidence and boundary tests match **Required tests**.

## Measured layout and gas

`forge inspect DcaManager storageLayout --json`: `DcaSchedule` is **96 bytes** (three slots). Before: 224 bytes, seven slots, one `uint256`/`bool` per field. After:

| Slot | Offset | Field | Type |
|---|---|---|---|
| 0 | 0 | `tokenBalance` | `uint128` |
| 0 | 16 | `purchaseAmount` | `uint128` |
| 1 | 0 | `purchasePeriod` | `uint32` |
| 1 | 4 | `lastPurchaseTimestamp` | `uint48` |
| 1 | 10 | `routeIndex` | `uint32` |
| 1 | 14 | `paused` | `bool` |
| 2 | 0 | `scheduleId` | `bytes32` |

`s_dcaSchedules` remains mapping slot 2. Handler `s_shares` / idle balances stay `uint256`.

Measured on `DcaScheduleTest` / `RbtcPurchaseTest` against the R49 base (`LENDING_PROTOCOL=sovryn`). The purchase-path drop is the R19 extra slot coming back out, plus the four other schedule slots collapsing:

| Test | R49 (unpacked + paused) | R18 | Delta |
|---|---|---|---|
| `testCreateDcaSchedule` | 336,242 | 285,004 | −51,238 |
| `testIntentSpecificScheduleEdits` (deposit + two updates) | 217,826 | 212,620 | −5,206 |
| `testDeleteDcaSchedule` | 563,822 | 489,032 | −74,790 |
| `testSinglePurchase` | 307,788 | 285,208 | −22,580 |
| `testBatchPurchasesOneUser` (5 rows) | 2,446,343 | 2,229,154 | −217,189 |

R19's unpacked `paused` had cost the protocol-paid purchase path +3,585 / +76,492. Packing more than returns that: `_rBtcPurchaseChecksEffects` now copies three cold slots per row instead of seven.

`DcaManager` runtime 21,151 bytes (margin 3,425). SafeCast inlining grew bytecode; the gas win is storage, not code size. Dex handlers are unchanged (21,105 / 21,361).

Timestamp arithmetic in the purchase path is done in `uint256` then `toUint48`, so a `uint48.max` last-purchase plus a period does not panic in the packed type before the named overflow revert.

## ABI / deploy / cutover impact

- ABI: `DcaSchedule` component types/order change. Getter tuple is now `(uint128 tokenBalance, uint128 purchaseAmount, uint32 purchasePeriod, uint48 lastPurchaseTimestamp, uint32 routeIndex, bool paused, bytes32 scheduleId)`. Function **inputs** stay `uint256`. Events still emit `uint256` amounts/periods. `scheduleId` moves from position 5 to last so positional ABI decoding must be regenerated — named-field consumers only need the new widths.
- Scripts: route constants fit `uint32`; `registerRoute` / `assignTokenHandler` revert `SafeCastOverflowedUintDowncast(32, …)` above that. No address/config change.
- Cutover: frontend ABI/types must update. Comment on BitChillRSK/front-end#19 (it already waited on this reorder) and BitChillRSK/data-api#9 §5. Function selectors are unchanged.
