# R50 — Packing follow-up (uint64 scheduleId, fees, admin, scalars, dex)

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 43 of the relaunch stack. Spec assigned in GitHub [#93](https://github.com/BitChillRSK/dca-contracts/pull/93). Implement stacked on that planning PR (which sits on R36, PR 42, [#92](https://github.com/BitChillRSK/dca-contracts/pull/92)). Land immediately after R36, before R37 and well before R9.

## Objective

Finish the storage packing R18 left on the table: each `DcaSchedule` occupies two slots with a public `uint64 scheduleId` equal to the monotonic nonce (no keccak); pack `FeeHandler` settings, the OperationsAdmin `(token, routeIndex)` handler+pause pair, DcaManager protocol scalars, and the two Uniswap slippage percents. Put every OperationsAdmin route-index argument through the same `uint32` bound as `registerRoute` / `assignTokenHandler`. Do not narrow handler per-user financial mappings.

## Background

R18 packed `DcaSchedule` from seven unpacked words to three slots and left 17 bytes unused in slot 1 because `bytes32 scheduleId` cannot share a slot. The id’s uniqueness already comes from `s_scheduleNonce` (`AGENTS.md` invariant 7). R6 hashed `(user, token, nonce)` only to keep ids opaque and hard to confuse with `scheduleIndex`, not for secrecy or collision resistance — ids are stale-index checks, not capabilities, and are public via `getDcaSchedules`.

Decided 2026-08-28: **store and pass the nonce as `uint64 scheduleId`; remove the hash.** Slot 1 has room for a `uint64`. Dual representation (store nonce, pass hash) and truncated keccak were rejected: the first is two names for one value; the second does not save a slot versus storing the nonce.

R18 also listed fee configuration and OperationsAdmin mappings as out of scope. They are in scope here, together with DcaManager’s adjacent scalars and the Dex min-out percents. Handler `s_shares` / idle balances / accumulated rBTC stay `uint256` (closed: one word per user, narrowing saves no slot). Address-keyed bool bitmaps (`s_swappers`, `s_handlerAssigned`) are rejected: addresses are sparse, so they never share a bitmap word and cost extra bit math.

Keep `++s_scheduleNonce` as the uniqueness source. Dropping that write and hashing timestamps or array shape remints ids after swap-pop (invariant 7) and collides two creates in one transaction.

R18 review (not exploitable, owner-only): `registerRoute` / `assignTokenHandler` `toUint32()`, but `setDepositsPaused` still keys `s_depositsPaused` with the raw `uint256`. After R48’s handler-must-be-assigned check that write currently reverts on an unassignable index, but it is still a second key width. Once handler and pause share one `TokenRoute` value, every route-index argument — writers and getters — must use the same `toUint32()` bound as the packed `DcaSchedule.routeIndex`.

## Open product decisions

**none** — decided 2026-08-28 in the R18 follow-up discussion. Implement this spec as written.

## Measured (2026-08-28)

Layouts, from `forge inspect <contract> storageLayout` before and after.

- `IDcaManager.DcaSchedule` is **64 bytes**: slot 0 `tokenBalance|purchaseAmount`; slot 1
  `purchasePeriod` (offset 0), `lastPurchaseTimestamp` (4), `routeIndex` (10), `paused` (14),
  `scheduleId` (15) — 23 of 32 bytes used.
- `DcaManager` roots go from 8 to 5: `_owner`, `_pendingOwner`, `s_dcaSchedules` (2),
  `s_protocolSettings` (3), `s_tokenMinPurchaseAmounts` (4). The settings word is
  `minPurchasePeriod` (0), `maxSchedulesPerToken` (4), `defaultMinPurchaseAmount` (6),
  `scheduleNonce` (22) — 30 of 32 bytes.
- `OperationsAdmin` roots go from 6 to 5; `s_tokenRoute` (2) holds `handler` (0) + `depositsPaused` (20).
- Handlers: fee state is two slots — slot 2 `s_feeCollector` (0) + `s_minFeeRate` (20) +
  `s_maxFeeRate` (22), slot 3 the two `uint128` bounds. **The collector is declared before the rates
  on purpose**: declared after, the two `uint16`s fall into the 12 bytes Ownable2Step leaves free
  beside `_pendingOwner` and the collector is pushed into a slot of its own, which is the opposite of
  what `_transferFee` wants.
- Dex handlers: `s_mocOracle` (6), then `s_amountOutMinimumPercent` + `s_amountOutMinimumSafetyCheck`
  packed in slot 7, then `s_swapPath`.

Gas, `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC`, vs R36:

| Test | R36 | R50 | Δ |
|---|---|---|---|
| `testCreateDcaSchedule` | 285,004 | 254,545 | −30,459 |
| `testSinglePurchase` | 285,295 | 279,088 | −6,207 |
| `testBatchPurchasesOneUser` | 2,229,154 | 2,150,566 | −78,588 |

**Runtime size is the cost, and it is not small.** Narrow fields mean mask/shift code on every read
and write, and the default (non-`via_ir`) profile does not optimise that away. Default profile,
EIP-170 24,576:

| Contract | R36 | R50 | Margin after |
|---|---|---|---|
| `DcaManager` | 21,151 | 22,585 | 1,991 |
| `LayerBankErc20HandlerDex` | 21,578 | 23,032 | 1,544 |
| `SovrynErc20HandlerDex` | 21,105 | 22,572 | 2,004 |
| `LayerBankDocHandlerMoc` | 15,752 | 16,707 | 7,869 |
| `SovrynDocHandlerMoc` | 15,318 | 16,286 | 8,290 |
| `IdleDocHandlerMoc` | 11,056 | 12,036 | 12,540 |
| `OperationsAdmin` | 6,049 | 6,002 | 18,574 |

R38, R42, R9, and R10 still have to fit inside those margins. `FOUNDRY_PROFILE=deploy` (via IR)
compiles the same sources to roughly half these sizes — `DcaManager` 11,062, the LayerBank dex
handler 11,454 — so the ceiling is a default-profile problem, not a deploy blocker, but the next PR
that adds a few hundred bytes to a dex handler should check `forge build --sizes` before pushing.

## Scope

### DcaSchedule: two slots, public nonce id

- [x] Field order and widths:

  ```
  slot 0: uint128 tokenBalance + uint128 purchaseAmount
  slot 1: uint32 purchasePeriod + uint48 lastPurchaseTimestamp
          + uint32 routeIndex + bool paused + uint64 scheduleId
  ```

  `scheduleId` is the last field so swap-pop and `vm.load` tests stay obvious. 4+6+4+1+8 = 23 bytes in slot 1.

- [x] Remove `keccak256(abi.encodePacked(msg.sender, token, ++s_scheduleNonce))`. On create, `uint64 scheduleId = (++s_scheduleNonce).toUint64()` and store that value. No hash anywhere (create, validate, events, errors, `PurchaseRbtc.batchBuyRbtc`, getters).

- [x] First live id is **1**. Today the counter starts at 1 and pre-increment hashes with 2, leaving nonce 1 unused. Change the counter so `getSchedulesCreatedCount()` equals the last assigned id: initialise `s_scheduleNonce` at 0, pre-increment on create, return `s_scheduleNonce` from `getSchedulesCreatedCount()`. Indexers that compare that getter to the number of `DcaScheduleCreated` logs keep working.

- [x] `_validateScheduleId` stays a straight `==` on `uint64`. It remains the swap-pop stale-index guard; do not drop the id check or accept index-only calls.

- [x] External function arguments that are amounts, periods, or route indexes stay `uint256` with OZ `SafeCast` at the storage boundary (R18). `scheduleId` is the exception: it is `uint64` in the ABI (calldata, events, errors, `DcaSchedule` tuple, `bytes32[]` → `uint64[]` on `batchBuyRbtc`). Calldata still ABI-pads to 32 bytes; the win is storage, not calldata.

- [x] Overflow on `++s_scheduleNonce` uses `SafeCast` (`toUint64`) before the struct write. `type(uint64).max` creates are not a practical test; bound the increment in a unit test that sets the counter near the cap via `vm.store`.

### FeeHandler

- [x] Storage, two slots (after Ownable2Step’s `_owner` / `_pendingOwner`):

  ```
  slot A: uint16 minFeeRate + uint16 maxFeeRate + address feeCollector
  slot B: uint128 feePurchaseLowerBound + uint128 feePurchaseUpperBound
  ```

  Rates are already capped at `MAX_FEE_RATE_CAP = 500`. Bounds are purchase amounts, so `uint128` matches the schedule. `_feeSettings()` becomes two SLOADs; if the collector lives in the rate slot it is already warm for `_transferFee`.

- [x] `IFeeHandler.FeeSettings` matches those widths (`uint16` / `uint16` / `uint128` / `uint128`). `setFeeRateParams` and the constructor keep `uint256` arguments (or untyped literals into the struct) and `SafeCast` at the write. Do not add assembly.

### OperationsAdmin `(token, routeIndex)` pair and uint32 keys

- [x] Replace `s_tokenHandler` and `s_depositsPaused` with one mapping whose value packs in a single slot:

  ```solidity
  struct TokenRoute {
      address handler;
      bool depositsPaused;
  }
  mapping(address token => mapping(uint256 routeIndex => TokenRoute)) private s_tokenRoute;
  ```

  `getTokenHandler` / `areDepositsPaused` / `assignTokenHandler` / `setDepositsPaused` keep their selectors and semantics. A missing handler is still `handler == address(0)` with `depositsPaused == false`.

- [x] Apply R18’s `toUint32()` bound to **every** OperationsAdmin function that takes a route index, not only `registerRoute` / `assignTokenHandler`. That is `setDepositsPaused`, `areDepositsPaused`, `getTokenHandler`, `isLendingRoute`, and `getRouteClass`. Oversized indexes revert `SafeCastOverflowedUintDowncast` instead of reading or writing a slot no packed schedule can store. This is the R18 review note: the pause path still used a raw `uint256` key.

- [x] Do not bitmap-pack `s_swappers` or `s_handlerAssigned`. Do not change mapping *key types* (`uint256` in the mapping declaration is fine; the bound is at the ABI boundary).

### DcaManager protocol scalars

- [x] Reorder so `s_tokenMinPurchaseAmounts` no longer sits between the scalars. Pack into one slot (internal struct or consecutive value types; not a new public type):

  ```
  uint32 minPurchasePeriod + uint16 maxSchedulesPerToken
  + uint128 defaultMinPurchaseAmount + uint64 scheduleNonce
  ```

  4+2+16+8 = 30 bytes. Owner setters and `createDcaSchedule` already read these together; packing them with the nonce means one SLOAD / one SSTORE on create. Token-specific mins stay a `mapping(address => uint256)` — **do not** narrow the mapping value type; it saves no slot.

- [x] `uint16` is enough for `maxSchedulesPerToken`; `SafeCast` on the owner setter. Period already has a `uint32` bound from R18.

### PurchaseUniswap slippage percents

- [x] Pack `s_amountOutMinimumPercent` and `s_amountOutMinimumSafetyCheck` as two `uint128`s in one slot. They are 1e18-scaled fractions (`HUNDRED_PERCENT = 1 ether`); `uint128` is ample. External setters/getters may stay `uint256` with `SafeCast`. Leave `s_mocOracle` and `s_swapPath` as they are.

### Layout, gas, consumers

- [x] `forge inspect DcaManager storageLayout`, `FeeHandler` (via a concrete handler), `OperationsAdmin`, and a Dex handler before/after. Record `DcaSchedule` **64 bytes**. Record gas for `testCreateDcaSchedule`, `testSinglePurchase`, `testBatchPurchasesOneUser` vs R36/R18.

- [x] Swap-pop still copies every packed field, including `uint64 scheduleId` and `paused`.

- [x] Clarify `AGENTS.md` invariant 7: the public `scheduleId` **is** the nonce (`uint64`), never a hash and never array state.

- [x] Open or update consumer issues (`AGENTS.md` **Consumer follow-up**): every `bytes32 scheduleId` in functions, events, and errors becomes `uint64`; `getDcaSchedule` / `getDcaSchedules` tuple and `getFeeSettings` change; `batchBuyRbtc` takes `uint64[]`. Named-field clients still need the new widths. Selectors and topic0s that mention `scheduleId` all change.

## Out of scope

- [ ] Narrowing `LendingErc20Handler.s_shares`, `IdleErc20Handler` balances, or `PurchaseRbtc` accumulated rBTC.
- [ ] Bitmap-packing `s_swappers` / `s_handlerAssigned`.
- [ ] Storing a hash (full or truncated) or a dual nonce-in-storage / hash-in-ABI id.
- [ ] Dropping `s_scheduleNonce` or deriving ids from timestamps, array length, or last-element state.
- [ ] Dropping the `(index, id)` check so calls are index-only.
- [ ] Assembly, unchecked truncation, proxy migration, token-decimal changes.
- [ ] R37 Tropykus retirement, R38 withdraw-all pairs, R42 batcher, R9 freeze, R10 natspec.
- [ ] Flattening the fee model or changing interpolation.

## Files likely touched

- `src/interfaces/IDcaManager.sol`, `src/DcaManager.sol`
- `src/interfaces/IPurchaseRbtc.sol`, `src/PurchaseRbtc.sol`
- `src/interfaces/IFeeHandler.sol`, `src/FeeHandler.sol`
- `src/interfaces/IOperationsAdmin.sol`, `src/OperationsAdmin.sol`
- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol`
- `AGENTS.md` (invariant 7 wording)
- `test/unit/SchedulePackingTest.t.sol`, `test/unit/OperationsAdminTest.t.sol`, fee and Uniswap unit tests, fuzz/invariant handlers, and every test that types `bytes32 scheduleId`

## Required tests

- `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract SchedulePackingTest`
- Assert `DcaSchedule` is 64 bytes / two slots via `vm.load` (slot 0 = two `uint128`s; slot 1 holds period, timestamp, route, paused, and `uint64` id).
- First created schedule has `scheduleId == 1`; second has `2`; `getSchedulesCreatedCount()` matches.
- `_validateScheduleId` still rejects a stale index after swap-pop when the id is the survivor’s nonce.
- `createDcaSchedule` near `type(uint64).max` reverts `SafeCastOverflowedUintDowncast` before cash moves (`vm.store` the packed nonce slot).
- FeeHandler: two storage slots for the five logical fields; `setFeeRateParams` still enforces cap / min≤max / lower<upper; `getFeeSettings` returns the packed types.
- OperationsAdmin: `assignTokenHandler` then `setDepositsPaused` dirty the same value slot (`vm.load`); `getTokenHandler` / `areDepositsPaused` unchanged for in-range indexes; unassigned pair is `(0, false)`.
- `setDepositsPaused` / `areDepositsPaused` / `getTokenHandler` / `isLendingRoute` / `getRouteClass` revert `SafeCastOverflowedUintDowncast` on `uint32.max + 1`, matching `registerRoute` / `assignTokenHandler`.
- DcaManager scalars: one slot for period / max-schedules / default min / nonce; token min-amount mapping still its own root.
- Dex: the two slippage percents share one slot; min-out math unchanged.
- Then `make check`, `make fork-sovryn`, `make fork-tropykus`.

## Success criteria

- [x] One `DcaSchedule` element occupies exactly two storage slots.
- [x] No keccak in the schedule-id path; public id is `uint64` nonce starting at 1.
- [x] Fee settings occupy two slots; OperationsAdmin handler+pause occupy one mapping value; DcaManager scalars occupy one slot; Dex percents occupy one slot.
- [x] Every OperationsAdmin route-index argument is `toUint32()`-bounded, including `setDepositsPaused`.
- [x] Handler financial mappings remain `uint256`.
- [x] Invariant 7 still holds (counter-derived ids) and is worded as nonce-as-id.
- [x] Consumer issues opened or updated; no open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Chosen maxima are enforced before cash/state mutation.
- [ ] Protocol invariants in `AGENTS.md` still hold (invariant 7 wording updated as specified).
- [ ] Layout/gas evidence and tests match **Required tests**.
- [ ] Files beyond this list are named in the PR.

## ABI / deploy / cutover impact

- ABI: **yes, large.** `scheduleId` changes `bytes32` → `uint64` on every function, event, and error that carries it, including `batchBuyRbtc`’s array. `DcaSchedule` tuple ends with `uint64 scheduleId` and is 64 bytes in storage. `FeeSettings` component types narrow. Event topic0s that include `scheduleId` change. Amount/period/route **inputs** stay `uint256`. Route-index getters/setters on OperationsAdmin can now revert `SafeCastOverflowedUintDowncast` the way `registerRoute` already does; selectors unchanged.
- Scripts: constructor `FeeSettings` literals still compile (untyped integer literals). Route constants unchanged. No address/config change.
- Cutover: regenerate types from this ABI before R9. Implementer opens or comments on consumer issues in the same turn as the Solidity PR (`front-end`, `swapper-bot`, `bitchill-monitoring`, `data-api`, `metrics-dashboard`).
