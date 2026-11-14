# Krait Rescan Candidates — Phase 1b

Hard exit rule: Pass 1 produced candidates above Info (C-01, C-02, C-04, C-06, C-11 at Medium) → proceed.

## Exclusion list (Pass 1)

- [MEDIUM] DcaManager.sol:347 — windows can be chained with no gap
- [MEDIUM] PurchaseUniswap.sol:231 — only the 97% oracle floor binds when `minRbtcOut` is loose
- [LOW] LendingHandler.sol:173 — tail purchase reverts `InsufficientShares`
- [MEDIUM] LayerBankHandler.sol:88 — redeem sizing assumes half-up burn rounding
- [LOW] DcaManager.sol:194 — period edit can make a schedule due again the same day
- [MEDIUM] DcaManager.sol:712 / LendingHandler.sol:139 — principal debited by request, payout may be lower
- [LOW] PurchaseFees.sol:78 — collector rotation leaves accrued rBTC on the old address
- [LOW] PurchaseFees.sol:56 — fee change applies at once
- [LOW] PurchaseRbtc.sol:159 — floor dust uncredited
- [LOW] PurchaseUniswap.sol:270 — floor assumes a 1 USD stablecoin
- [MEDIUM] DcaManager.sol:498 — one failing row or illiquid venue aborts the batch
- [LOW] DcaManager.sol:279 — top-up not covered by the deposit pause
- [LOW] PurchaseUniswap.sol:148 — swapper can re-activate an allowlisted path
- [LOW] PurchaseRbtc.sol:128 — rBTC payable only to the recorded account
- [LOW] PurchaseMoc.sol:43 — MoC route has no on-chain price floor
- [LOW] LendingHandler.sol:49 — zero-cash interest redeem reverts the multi-pair call
- [LOW] PurchaseUniswap.sol:326 / LendingHandler.sol:115 — standing max approvals
- [LOW] DcaManager.sol:389 — schedule cap up to 65,535 with a linear loop
- [LOW] DcaManager.sol:540 — new schedule purchasable at once

## Blind spots (zero candidates in Pass 1) — priority targets

`OperationsAdmin.sol`, `TokenHandler.sol`, `IdleHandler.sol`, `SovrynHandler.sol`, `StablecoinSource.sol`,
`DcaManagerAccessControl.sol`, `BitChillOwnable.sol`, and the seven constructor-only leaves.

## Rescan pass A — registry, access bases, leaves, idle

Looked for: paired-function mismatches, constructor-argument order across the diamond, immutables read
before assignment, ERC-165 id consistency, asymmetry between assignment-time checks and call-time casts.

- Leaf constructors: argument order matches each base signature in all seven leaves
  (`PurchaseMoc(mocProxy, FeeConfig, initialOwner)`, `PurchaseUniswap(settings, FeeConfig, percent, safety, owner)`).
- Linearization: `StablecoinSource` and `DcaManagerAccessControl` are bases of both branches, so they are
  constructed before `PurchaseUniswap`'s constructor reads `i_stablecoin`; `i_wrbtc`/`i_swapRouter`/
  `i_pool`/`i_iToken` are assigned before the helper that reads them.
- `assignHandler`: `supportsInterface` ids are `type(I).interfaceId` on both sides (inherited
  `i_stablecoin` selector excluded on both); lending class ↔ `ILendingHandler` enforced both ways, so
  `DcaManager` can always cast a lending-route handler.
- `getRouteClass` / `getHandler` / `areDepositsPaused` all `toUint32()` their index; a value above
  `uint32` reverts in every caller rather than aliasing another route.

### [RS-1] Handler assignment and route class are irreversible; a mistaken call burns the pair

**Severity**: LOW
**File**: src/OperationsAdmin.sol
**Lines**: 63-70, 79-112
**Category**: missing-inverse (MISSING-01)
**Description**: no `unassign` and no reclassification. A wrong but interface-conformant handler stays on
`(token, routeIndex)` forever; the only brake is `setDepositsPaused`.
**Depth Evidence**: [TRACE:assignHandler(token,1,H) → assignHandler(token,1,H2) → revert HandlerAlreadyAssigned]
**Precondition Type**: ACCESS (owner)
**Status**: UNVERIFIED

### [RS-2] `assignHandler` trusts values the handler reports about itself

**Severity**: LOW
**File**: src/OperationsAdmin.sol
**Lines**: 91-107
**Category**: validation
**Description**: `supportsInterface`, `i_stablecoin()`, and `i_dcaManager()` are answered by the candidate
handler; a non-BitChill contract can answer all three as required. The DcaManager it names only has to be
pinned to this registry, and anyone can deploy such a DcaManager.
**Depth Evidence**: [TRACE:attacker DcaManager' pinned to real admin + handler' → still needs owner to call assignHandler]
**Precondition Type**: ACCESS (owner)
**Status**: UNVERIFIED

### [RS-3] Pooled idle custody has no handler-side per-user book

**Severity**: LOW
**File**: src/idle/IdleHandler.sol
**Lines**: 37-50
**Category**: defense-in-depth
**Description**: `IdleHandler` pays whatever `DcaManager` asks from pooled cash. No discrepancy path was
found (see SAFE verdict "Idle pooled custody"); the note is that the two exactness checks are the only
thing separating users on idle routes.
**Status**: UNVERIFIED

## Rescan pass B — DcaManager ↔ handlers, between the areas Pass 1 examined

Looked for: invariants set by one function and broken by another; create/consume pairs; time-dependent
state under specific sequences.

### [RS-4] `purchaseAmount ≤ tokenBalance` is enforced on create and edit but not preserved by withdrawals

**Severity**: LOW
**File**: src/DcaManager.sol
**Lines**: 187, 621-633 vs 712-736
**Category**: asymmetric-validation (Q3.2)
**Description**: `_validatePurchaseAmount` refuses an amount above the balance, but `withdrawToken` can
then leave `tokenBalance < purchaseAmount`. Such a schedule reverts any batch that names it with
`ScheduleBalanceNotEnoughForPurchase`.
**Depth Evidence**: [TRACE:create(100, purchase 100) → withdrawToken(60) → batch row → revert ScheduleBalanceNotEnoughForPurchase]
**Status**: UNVERIFIED

### [RS-5] The protected window is one global lock across every token and route

**Severity**: LOW
**File**: src/DcaManager.sol
**Lines**: 61, 347-358
**Category**: restriction-scope
**Description**: a window opened for one handler's batch blocks exits on all seven handlers.
**Status**: UNVERIFIED

### [RS-6] Raising a token's minimum purchase amount can make an existing schedule un-editable

**Severity**: LOW
**File**: src/DcaManager.sol
**Lines**: 179-191, 395-401
**Category**: parameter-transition
**Description**: after `setTokenMinPurchaseAmount(token, M')`, a schedule with `tokenBalance < M'` cannot
call `updatePurchaseAmount` (needs `M' ≤ amount ≤ balance`) until it deposits. It keeps purchasing at its
old amount and can still withdraw or delete.
**Depth Evidence**: [BOUNDARY:balance 30, min 25→50 → update(any) reverts; purchase of 25 still executes]
**Status**: UNVERIFIED

## Reinforced

- C-11: `RS-4` is one more way a row becomes unbuyable between the bot's read and inclusion; also blocked
  by the window (withdrawals are guarded).
- C-06: the deposit-rounding case on LayerBank (`rayDiv` rounds the mint down) leaves value = deposit − 1
  unit immediately, so a `purchaseAmount == depositAmount` schedule fails its first row until the index
  moves. Same root cause as C-03.

Rescan complete: 6 new candidates (0 high, 0 medium, 6 low).
