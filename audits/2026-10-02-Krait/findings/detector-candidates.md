# Krait Detector Candidates — Phase 1

Scope: `src/` excluding `src/tropykus-legacy/`. Strategy: MEDIUM codebase, tiered 3-pass. All 20
implementation files and 17 interfaces were read in full regardless of tier. Recall-oriented: several
entries below are recorded so the Critic can rule on them explicitly, including ones the documentation
already describes.

## Function-State Matrix (Tier 1)

### DcaManager

| Function | Vis | Reads | Writes | Guards | External calls |
|---|---|---|---|---|---|
| createDcaSchedule | ext | settings, min amount, ids | nonce, schedule, ids | nonReentrant; token≠0; SafeCast; period, deposit, amount checks; cap | admin.getHandler, areDepositsPaused; handler.depositToken |
| depositToken | ext | schedule | tokenBalance | nonReentrant; owner; >0; uint128 | admin ×2; handler.depositToken |
| updatePurchaseAmount | ext | schedule, min | purchaseAmount | window; nonReentrant; owner; min ≤ amt ≤ balance | — |
| updatePurchasePeriod | ext | schedule, settings | purchasePeriod | window; nonReentrant; owner; ≥min, whole days | — |
| setSchedulePaused | ext | schedule | paused | window; nonReentrant; owner | — |
| deleteDcaSchedule | ext | schedule, ids | ids (swap-pop), schedule (delete) | window; nonReentrant; owner; index check | admin.getHandler; handler.withdrawToken |
| withdrawToken | ext | schedule | tokenBalance | window; nonReentrant; owner; 0 < amt ≤ balance | admin.getHandler; handler.withdrawToken |
| withdrawTokenAndInterest | ext | + ids, schedules | tokenBalance | same + lending route | + admin.getRouteClass; handler.withdrawInterest |
| topUpFromInterest | ext | schedule, ids | tokenBalance | nonReentrant; owner; lending route; amt ≤ accrued; crosses a purchase boundary | admin ×2; handler.getAccruedInterest |
| withdrawAllAccumulatedInterest | ext | ids, schedules | — | window; nonReentrant; paired arrays | admin ×2 per pair; handler.withdrawInterest |
| withdrawAccumulatedRbtc | ext | — | — | nonReentrant | admin.getHandler; handler.withdrawAccumulatedRbtc |
| withdrawAllAccumulatedRbtc | ext | — | — | nonReentrant; paired arrays | per pair: admin, handler ×2 |
| activateProtectedPurchaseWindow | ext | lock block | lock block | onlySwapper; no live window | admin.isSwapper |
| batchBuyRbtc / AcrossHandlers | ext | schedules | tokenBalance, cadenceAnchor | onlySwapper; exists; !paused; due; balance; route | admin; handler.batchBuyRbtc |
| setMinPurchasePeriod / setMaxSchedulesPerToken / setTokenMinPurchaseAmount | ext | — | settings / mins | onlyOwner (+ validation) | — |

Modifier sibling diff (MODIFIER-01): every external writer of `s_dcaSchedules` carries `nonReentrant`
except the two `onlySwapper` purchase entries; exactly the seven documented mutators carry
`whenUserMutationsAllowed`. `createDcaSchedule`, `depositToken`, `topUpFromInterest`, and both rBTC
withdrawals are deliberately outside the window set. No unexplained gap.

### PurchaseRbtc / PurchaseFees / PurchaseUniswap / LendingHandler / TokenHandler / OperationsAdmin

| Function | Guard | Writes | External calls |
|---|---|---|---|
| PurchaseRbtc.batchBuyRbtc | onlyDcaManager | s_accumulatedRbtc (buyers, collector) | stablecoin.balanceOf ×2, venue, lending redeem |
| PurchaseRbtc.withdrawAccumulatedRbtc | onlyDcaManager | s_accumulatedRbtc[user] = 1 | (WRBTC.withdraw) user.call{value} |
| PurchaseRbtc.receive | none (by design) | — | — |
| PurchaseFees.setFeeRateParams / setFeeCollector | onlyOwner | fee settings / collector | — |
| PurchaseUniswap.setPurchasePathAllowed | onlyOwner | allowlist | — |
| PurchaseUniswap.setPurchasePath | owner or swapper (inline); path allowlisted | path, intermediates | dcaManager.i_operationsAdmin().isSwapper |
| PurchaseUniswap.setAmountOutMinimumPercent / SafetyCheck / setMocOracle | onlyOwner | floor / bound / oracle | — |
| PurchaseUniswap.restoreSwapRouterApproval | none (by design) | allowance | stablecoin.approve |
| TokenHandler.depositToken / withdrawToken | onlyDcaManager | (lending: s_shares) | stablecoin, lending protocol |
| LendingHandler.withdrawInterest / getAccruedInterest | onlyDcaManager | s_shares | lending protocol, stablecoin |
| LendingHandler.restoreLendingApproval | none (by design) | allowance | stablecoin.approve |
| OperationsAdmin.registerRoute / assignHandler / setDepositsPaused / addSwapper / revokeSwapper | onlyOwner | registry | handler views (assign) |

## PASS 1 BRIEF

- Candidates found: C-01 … C-12 (below, one line each in the exclusion list of the rescan).
- Files with NO candidates after Pass 1: `OperationsAdmin.sol`, `TokenHandler.sol`, `IdleHandler.sol`,
  `SovrynHandler.sol`, `StablecoinSource.sol`, `DcaManagerAccessControl.sol`, `BitChillOwnable.sol`,
  all seven leaves.
- Suspicious areas flagged but not promoted: non-reentrant swapper path (handlers trusted, effects first);
  `receive()` open on every handler (donations inert because all accounting is delta- or book-based);
  standing max approvals to router / lending spender.
- Slither findings not covered by a candidate: none (all four High are false positives, see
  `.audit/slither-summary.md`).

## Pass 2 — Lens results

- **Lens A (access/state)**: permission map above; no state writer without a guard other than the three
  documented permissionless functions. Role escalation: none (swapper cannot add itself, owner two-step,
  renounce disabled). State machine: schedule nonexistent → live → deleted; ids never reused (nonce).
  New: C-13, C-14.
- **Lens B (value/economics)**: wei trace of a batch (`G` planned, `R` retrieved, `Q` measured):
  buyers `Σ floor(Q·netᵢ/G)` + collector `floor(Q·F/G)` ≤ `Q` for every sampled input
  (50,000 random batches, max uncredited 27 wei in a 40-row batch). Share conversions: `ceil` debit never
  exceeds held shares when amount ≤ floor value; payout ≥ amount. No first-depositor surface: user shares
  are the protocol's own receipt units, there is no BitChill-level share price. New: C-15, C-16.
- **Lens C (external)**: every integrator return value is ignored in favour of balance deltas; partial
  MoC fill, partial share burn, and router-stranded intermediates all revert. On-behalf calls
  (Aave `supply(onBehalfOf)`, Sovryn `mint(receiver)`) only donate. Aave flash loan naming a handler as
  receiver reverts (no `fallback`, no `executeOperation`). New: C-17.
- **Lens D (edge/math/standards)**: mechanical traces of `_calculateVariableFee` (cap, monotonicity,
  continuity at `L`: 0 violations in 200,000 samples), `_underlyingForExactScaledBurn` (0 mismatches in
  300,000 samples for index ∈ [RAY, 3·RAY), never exceeds the aToken balance), cadence grid (7 traces).
  Casts: all `SafeCast` except one bounded `uint128(...)` at `DcaManager.sol:727`. ERC-165 ids are
  computed with `type(I).interfaceId` on both sides. New: C-18, C-19.

Consensus tags are on each candidate.

---

### [C-01] Swapper can chain protected windows with no gap, holding user exits locked

**Severity**: MEDIUM
**File**: src/DcaManager.sol
**Lines**: 347-358, 490-495
**Category**: denial-of-service / access-control
**Discovery Method**: Lens A [Attacker]; MISSING-02 restriction coverage; Q3.9 paired operation (no cooldown)
**Consensus**: moderate (Pass 1 + Lens A)

**Description**: `activateProtectedPurchaseWindow` only requires `block.number >= s_userMutationsAllowedFromBlock`.
A swapper can re-activate in the first transaction of block `N+5`, so `withdrawToken`,
`withdrawTokenAndInterest`, `deleteDcaSchedule`, `withdrawAllAccumulatedInterest` and the three edits stay
refused for as long as the swapper wins that ordering. The lock is global across tokens and routes.

**Scenario**:
1. Swapper key is compromised (or malicious). It activates at block `N`.
2. At `N+5` it re-activates with a higher gas price than user exits; repeat.
3. Users cannot withdraw principal or interest, cannot pause or delete.
4. Result: principal exits blocked until the owner calls `revokeSwapper`.

**Vulnerable Code**:
```solidity
if (block.number < userMutationsAllowedFromBlock) revert DcaManager__ProtectedPurchaseWindowStillActive(...);
unchecked { userMutationsAllowedFromBlock = block.number + PROTECTED_PURCHASE_WINDOW_BLOCKS; }
```

**Why This Is a Bug**: A semi-trusted role documented as "not trusted for custody" can hold custody exits shut.

**Step Execution**: Lens: A=✓ B=✓ C=✗(no external call) D=✓
**Rules Applied**: [R8:✗(no cached external state), R10:✓(worst state: every block N+5 won by swapper), R11:✗, R12:✓(only enabler: allowlisted swapper), R15:✗, R16:✗]
**Depth Evidence**: [BOUNDARY:block.number = allowedFrom → activation succeeds], [TRACE:activate@N → withdrawToken@N+4 → revert UserMutationsLocked], [TRACE:user tx ordered before re-activation in N+5 → succeeds]
**Missing Precondition**: attacker must be on the swapper allowlist and win ordering in each `N+5` block
**Precondition Type**: ACCESS
**Postconditions Created**: user exits and pauses unavailable while chaining continues
**Postcondition Types**: ACCESS, TIMING
**Who Benefits**: compromised swapper (enables C-02 against locked-in users)

**Status**: UNVERIFIED — needs Critic validation

---

### [C-02] Dex purchase is bounded only by the 97% oracle floor when `minRbtcOut` is zero or stale

**Severity**: MEDIUM
**File**: src/PurchaseUniswap.sol
**Lines**: 231-237, 270-279
**Category**: MEV / slippage
**Discovery Method**: amm-mev-deep §6-7; multi-tx-attack §1; DEADLINE-BLOCKTIMESTAMP
**Consensus**: strong (Pass 1 + Lens B + Lens C)

**Description**: `amountOutMinimum = max(minRbtcOut, floor)` where `floor` is
`amountIn × scale × s_amountOutMinimumPercent / price`. With the deploy default (0.97e18) and a swapper
minimum that is zero, stale, or sat in the mempool (no deadline), a sandwicher can take the difference
between the fair fill (≈99.6% of oracle per the repo's own probe) and 97%.

**Scenario**:
1. Swapper submits a USDRIF batch of 10,000 with `minRbtcOut = 0`.
2. Attacker front-runs to push the pool, the batch fills at 97% of oracle, attacker back-runs.
3. Result: ≈2.6% of the batch (≈260 USD) extracted, shared pro rata by the batch's buyers.

**Vulnerable Code**:
```solidity
uint256 amountOutMinimum = minRbtcOut > amountOutLowerBound ? minRbtcOut : amountOutLowerBound;
```

**Why This Is a Bug**: the on-chain bound is 2.6 points looser than the observed fair fill.

**Step Execution**: Lens: A=✗(n/a) B=✓ C=✓ D=✓
**Rules Applied**: [R8:✗, R10:✓(worst state: minRbtcOut=0), R11:✗, R12:✓(enablers: zero/stale min, delayed inclusion), R15:✓(pool price is flash/sandwich-movable; floor is oracle-based, not pool-based), R16:✓(MoC oracle validity flag checked; zero price panics)]
**Depth Evidence**: [BOUNDARY:minRbtcOut=0 → amountOutMinimum=floor], [VARIATION:percent 0.97→1.0 → no slack], [TRACE:100e6 USDT0, price 60000e18 → floor 1.6167e15 wei]
**Missing Precondition**: swapper passes a loose minimum
**Precondition Type**: EXTERNAL
**Postconditions Created**: buyers credited up to 3% less rBTC
**Who Benefits**: sandwicher

**Status**: UNVERIFIED — needs Critic validation

---

### [C-03] Last purchase of a lending position reverts `InsufficientShares`, aborting the whole batch

**Severity**: LOW
**File**: src/LendingHandler.sol
**Lines**: 173-177, 245-251
**Category**: rounding / denial-of-service
**Discovery Method**: PR-03 dual conversion; Q5.2 last call
**Consensus**: strong (Pass 1 + Lens B + Lens D)

**Description**: each row debits `ceil(amount × scale / rate)`; after `N` purchases at a flat rate the
position is short by up to `N` share units, so the final row needs more shares than remain and
`_batchRetrieveStablecoin` reverts for every buyer in the batch.

**Scenario**: 52 purchases of 25 DOC at a flat Sovryn price → row 52 short by 45 share units (simulated).

**Step Execution**: Lens: A=✗ B=✓ C=✗ D=✓
**Rules Applied**: [R8:✗, R10:✓(flat-rate market), R11:✗, R12:✓, R15:✗(rate cannot be pushed down by a user), R16:✗]
**Depth Evidence**: [TRACE:52×25e18 @ price 1.2034e18 → row 52 short 45 units], [VARIATION:rate ↑ → fewer shares needed → row passes]
**Who Benefits**: nobody (liveness only)

**Status**: UNVERIFIED — needs Critic validation

---

### [C-04] LayerBank redeem sizing depends on the Pool's half-up burn rounding

**Severity**: MEDIUM
**File**: src/layerbank/LayerBankHandler.sol
**Lines**: 88-111
**Category**: external-integration / denial-of-service
**Discovery Method**: Q8.5 upgradeable dependency; EXT-02
**Consensus**: moderate (Pass 1 + Lens C)

**Description**: `_underlyingForExactScaledBurn` returns `floor(s·index/RAY)` plus one wei when half-up
`rayDiv` lands on `s−1`. If the Pool adopts upstream Aave's round-up burn, the `+1` case burns `s+1` and
`LendingHandler__ShareConsumptionMismatch` reverts purchases and user exits (25.2% of sampled redeems).

**Step Execution**: Lens: A=✗ B=✗ C=✓ D=✓
**Rules Applied**: [R8:✗, R10:✓, R11:✗, R12:✓(enabler: LayerBank implementation upgrade), R15:✗, R16:✗]
**Depth Evidence**: [TRACE:half-up, 300k samples → 0 mismatches], [VARIATION:half-up→round-up → 25.2% mismatch]
**Missing Precondition**: LayerBank upgrades the Pool/aToken
**Precondition Type**: EXTERNAL

**Status**: UNVERIFIED — needs Critic validation

---

### [C-05] Period edit after a late buy makes the schedule due again the same UTC day

**Severity**: LOW
**File**: src/DcaManager.sol
**Lines**: 194-205, 551-563
**Category**: business-logic
**Discovery Method**: Module M lifecycle (`cadenceAnchor` not updated by `updatePurchasePeriod`)
**Consensus**: moderate (Pass 1 + Lens D)

**Depth Evidence**: [TRACE:28d schedule bought 7d late, period→7d → due same day (simulated)]
**Who Benefits**: only the schedule owner, on their own balance

**Status**: UNVERIFIED — needs Critic validation

---

### [C-06] Principal is debited by the requested amount while a lending payout can be lower; no user minimum

**Severity**: MEDIUM
**File**: src/DcaManager.sol, src/LendingHandler.sol
**Lines**: DcaManager 712-736, 227-244; LendingHandler 139-152
**Category**: accounting / slippage
**Discovery Method**: state-coupling `tokenBalance ↔ s_shares`; masking clamp at LendingHandler:144-147
**Consensus**: strong (Pass 1 + Lens B + state analysis)

**Description**: `_withdrawToken` subtracts `withdrawalAmount` from the schedule and ignores the handler's
measured return; `deleteDcaSchedule` deletes the schedule regardless of the payout. If the user's shares
are worth less than the request (venue loss, exit fee, or the 1-unit rounding gap), the difference is
written off with no `minReceived` argument.

**Scenario**: Sovryn turns on a 0.5% exit fee; user withdraws 10,000 DOC principal, receives 9,950, schedule
shows 0.

**Step Execution**: Lens: A=✗ B=✓ C=✓ D=✓
**Rules Applied**: [R8:✗, R10:✓(loss event), R11:✗, R12:✓(enablers: exit fee, bad debt, rounding), R15:✗, R16:✗]
**Depth Evidence**: [BOUNDARY:shares=0 → clamp to 0 → transfer 0, principal still debited], [TRACE:deposit rounding leaves value = deposit−1 → full withdraw pays −1 unit]
**Who Benefits**: nobody inside BitChill (loss is external)

**Status**: UNVERIFIED — needs Critic validation

---

### [C-07] Rotating the fee collector leaves accrued rBTC under the old address

**Severity**: LOW
**File**: src/PurchaseFees.sol / src/PurchaseRbtc.sol
**Lines**: PurchaseFees 78-82; PurchaseRbtc 176-184
**Category**: state-coupling
**Discovery Method**: Module M admin side effects
**Consensus**: single (Lens A)

**Description**: fees are credited to `s_accumulatedRbtc[collector]` at purchase time. `setFeeCollector`
changes only the pointer; the balance already booked can be withdrawn only by the previous address
through `DcaManager.withdrawAccumulatedRbtc`. If the rotation was triggered by a lost or compromised
collector, that balance is lost or taken.

**Depth Evidence**: [TRACE:credit 1e15 to A → setFeeCollector(B) → getAccumulatedRbtcBalance(B)=0, A=1e15]
**Precondition Type**: ACCESS
**Who Benefits**: holder of the old collector key

**Status**: UNVERIFIED — needs Critic validation

---

### [C-08] Fee parameters apply at once to already-funded schedules, with no delay

**Severity**: LOW
**File**: src/PurchaseFees.sol
**Lines**: 56-75
**Category**: retroactive-parameter
**Discovery Method**: Pass 3 #6 parameter transition
**Consensus**: single (Pass 3)

**Depth Evidence**: [VARIATION:max 100→500 bps → next purchase of 25 DOC pays 1.25 instead of 0.25]

**Status**: UNVERIFIED — needs Critic validation

---

### [C-09] Floor dust from the rBTC split is never credited and cannot be swept

**Severity**: LOW
**File**: src/PurchaseRbtc.sol
**Lines**: 84-88, 159-170
**Category**: rounding
**Consensus**: moderate (Pass 1 + Lens B)

**Depth Evidence**: [TRACE:40-row batch → max 27 wei uncredited]

**Status**: UNVERIFIED — needs Critic validation

---

### [C-10] Dex floor prices the stablecoin at exactly 1 USD

**Severity**: LOW
**File**: src/PurchaseUniswap.sol
**Lines**: 270-279
**Category**: oracle
**Discovery Method**: oracle-analysis §6 "wrong price feed for derivative assets"
**Consensus**: moderate (Lens B + Lens C)

**Description**: USDRIF and USDT0 amounts are lifted to USD by decimals only. A stablecoin trading below
peg makes every swap miss the floor (purchases stop); above peg the floor is looser than intended by the
premium.

**Rules Applied**: [R16:✓(validity flag honoured; zero price → division panic → revert; no negative values, uint)]

**Status**: UNVERIFIED — needs Critic validation

---

### [C-11] One failing row or an illiquid venue aborts every buyer in the batch

**Severity**: MEDIUM
**File**: src/DcaManager.sol, src/PurchaseRbtc.sol, src/LendingHandler.sol
**Lines**: DcaManager 498-520; PurchaseRbtc 66-78; LendingHandler 187-192
**Category**: denial-of-service
**Discovery Method**: Pass 3 #7 DoS on core functions; Module N
**Consensus**: strong (Pass 1 + Lens A + Lens C)

**Description**: outside a protected window any user can pause, withdraw, edit or delete in front of the
swapper's transaction and revert the batch; an external party can borrow out a LayerBank reserve or
shrink MoC free DOC so the pooled redeem reverts.

**Scenario**: griefer with one 25-DOC schedule front-runs each batch with `setSchedulePaused(true)`.

**Depth Evidence**: [TRACE:paused row → DcaManager__SchedulePaused → whole batch reverts], [TRACE:same sequence inside a window → setSchedulePaused reverts UserMutationsLocked]
**Missing Precondition**: bot not using the window / not simulating
**Precondition Type**: TIMING

**Status**: UNVERIFIED — needs Critic validation

---

### [C-12] `topUpFromInterest` raises principal on a route whose deposits are paused

**Severity**: LOW
**File**: src/DcaManager.sol
**Lines**: 279-304, 691-697
**Category**: restriction-coverage
**Discovery Method**: MISSING-02 (pause covers create + deposit only)
**Consensus**: single (Pass 3)

**Description**: the deposit pause is described as a breaker for a lending market going bad;
`topUpFromInterest` resolves the handler with `_handler`, not `_handlerForDeposit`, so principal on that
market can still grow by the accrued interest. No cash moves.

**Status**: UNVERIFIED — needs Critic validation

---

### [C-13] A swapper can switch the active Dex path among allowlisted paths and race a revocation

**Severity**: LOW
**File**: src/PurchaseUniswap.sol
**Lines**: 132-160
**Category**: access-control
**Consensus**: single (Lens A)

**Depth Evidence**: [TRACE:owner revoke(path P) pending → swapper setPurchasePath(P) first → revoke reverts CannotRevokeActivePurchasePath]

**Status**: UNVERIFIED — needs Critic validation

---

### [C-14] rBTC can only be paid to the recorded account by native `call`

**Severity**: LOW
**File**: src/PurchaseRbtc.sol
**Lines**: 106-109, 128-132
**Category**: ETH handling
**Discovery Method**: ETH-02
**Consensus**: single (Lens A)

**Description**: a schedule owner (or fee collector) that is a contract without a payable
`receive`/`fallback` can never withdraw its accumulated rBTC; there is no alternate recipient.

**Status**: UNVERIFIED — needs Critic validation

---

### [C-15] MoC route has no on-chain price floor

**Severity**: LOW
**File**: src/PurchaseMoc.sol
**Lines**: 43-58
**Category**: slippage
**Consensus**: single (Lens B)

**Description**: `minRbtcOut` is ignored inside `_purchaseRbtc`; `PurchaseRbtc` enforces it afterwards,
and zero disables it. Output is whatever MoC's own price and commission produce.

**Status**: UNVERIFIED — needs Critic validation

---

### [C-16] `withdrawInterest` reverts instead of skipping when a positive share burn returns zero cash

**Severity**: LOW
**File**: src/LendingHandler.sol
**Lines**: 49-65, 294-308
**Category**: denial-of-service (edge)
**Discovery Method**: Q6.2 error path; batch loop in `DcaManager.withdrawAllAccumulatedInterest:314-321`
**Consensus**: single (Lens B)

**Description**: with interest of one unit and a venue exit fee that rounds the payout to zero,
`_redeemShares` reverts `ZeroStablecoinReceived`; that reverts `withdrawTokenAndInterest` and the whole
multi-pair `withdrawAllAccumulatedInterest` call. The user must retry without that pair or use
`withdrawToken`.

**Depth Evidence**: [BOUNDARY:interest=1, shares=1, price 1.2e18 → cash 1 (no revert today)], [VARIATION:exit fee on → cash 0 → revert]
**Missing Precondition**: a venue exit fee or a rate below 1
**Precondition Type**: EXTERNAL

**Status**: UNVERIFIED — needs Critic validation

---

### [C-17] Standing unlimited stablecoin approvals to SwapRouter02 and the lending spender

**Severity**: LOW
**File**: src/PurchaseUniswap.sol, src/LendingHandler.sol
**Lines**: PurchaseUniswap 326-328; LendingHandler 115-117
**Category**: external-integration
**Consensus**: single (Lens C)

**Description**: every idle Dex handler holds pooled user cash with `type(uint256).max` approved to the
router; a router or Pool bug that pulls from an arbitrary approver would reach it.

**Depth Evidence**: [TRACE:Aave flashLoanSimple(receiver=handler) → executeOperation → no fallback → revert]

**Status**: UNVERIFIED — needs Critic validation

---

### [C-18] `maxSchedulesPerToken` accepts up to 65,535 while `_lockedPrincipal` is linear

**Severity**: LOW
**File**: src/DcaManager.sol
**Lines**: 389-392, 753-769
**Category**: gas / DoS
**Consensus**: single (Lens D)

**Description**: at a large cap a user with thousands of schedules cannot run interest operations within
the block gas limit. Self-inflicted; no other account is affected.

**Status**: UNVERIFIED — needs Critic validation

---

### [C-19] A new schedule is purchasable in the block it is created

**Severity**: LOW
**File**: src/DcaManager.sol
**Lines**: 540-551
**Category**: business-logic
**Consensus**: single (Lens D)

**Description**: `cadenceAnchor == 0` skips the due check, so the first buy can execute immediately and at
any time of day chosen by the swapper.

**Status**: UNVERIFIED — needs Critic validation

---

## SAFE verdicts (with the invariant and edge cases checked)

| Area | Invariant verified | Edge cases |
|---|---|---|
| Idle pooled custody | Σ idle `tokenBalance` = handler stablecoin balance (+ donations) | deposit delta ≠ request → revert; purchase delta ≠ Σ amounts → revert; withdraw > schedule balance → revert; `type(uint256).max` on zero balance → revert |
| Lending share books | Σ `s_shares` ≤ external receipt shares | partial burn → revert; flat/rising balance → revert without panic; deposit mints 0 → revert; same buyer twice in a batch uses the running balance |
| Cross-user isolation (lending) | every outflow is bounded by the caller's own `s_shares` | understated locked principal only drains own shares; one handler per pair (`s_handlerAssigned`); handler stablecoin must equal the pair's token |
| rBTC books | Σ credits ≤ measured `Q`; payout = stored − 1 | never-credited (0), sentinel (1), credit after full withdraw, collector = buyer |
| Schedule ownership | only `_callersSchedule` gates mutators | wrong token for a real id → `InexistentSchedule`; other owner → `NotScheduleOwner`; deleted id; batch row under wrong token |
| Cadence | anchors are UTC midnights on the original grid | first buy; same-day repeat; late buy; multi-slot skip; `nextDue − block.timestamp` never underflows |
| Window | lock is exactly `[N, N+4]` | activation at `allowedFrom`; activation mid-window reverts; revoked swapper mid-window |
| Path state | active path is always allowlisted; intermediates match the path | revoke active → revert; no-op write → revert; constructor self-allowlist |
| Fee settings | `min ≤ max ≤ 500` | `L = 0`; `x = L`; `x = L+1`; flat (`min == max`) path |
