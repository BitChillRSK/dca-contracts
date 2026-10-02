# R110 — Internal audit follow-ups

Status: **implemented** · Assigned: yes · Optional/further-review: no · Stack on: R109 ([#175](https://github.com/BitChillRSK/dca-contracts/pull/175))

## Objective

Close the observations from an internal review of `src/` at `73e97387` (R108 head). It reported no
Critical, High, or Medium issue and six observations. This PR corrects two stale documents, adds the
missing underlying-token check to the Sovryn adapter (and the legacy Tropykus one), and records the
LayerBank burn-rounding assumption with a live probe. One contract behaviour changes: a Sovryn or
Tropykus handler now refuses to construct against a receipt token whose underlying is another asset.

## Background

### 1. `AUDIT_GUIDE.md` described the pre-R107 fee flow

The guide said a purchase consumes the "net" stablecoin and that fees are "transferred before the
venue call". Since [R107](./R107-rbtc-fees.md) the handler supplies the whole retrieved gross to the
venue and credits the fee as a share of measured rBTC afterwards (`PurchaseRbtc.batchBuyRbtc`).
`README.md` and the `src/` NatSpec were checked and already describe the current flow.

### 2. "No second buy in one UTC day" is conditional on an unchanged period

`AUDIT_GUIDE.md` and `IDcaManager.batchBuyRbtc` stated it unconditionally. `updatePurchasePeriod`
does not move `cadenceAnchor`, and the due day is `cadenceAnchor + purchasePeriod`. After a purchase
that lands at least one new period late, the anchor still sits on the old grid, so shortening the
period to no more than the lateness makes the schedule due again that day. Example: a 28-day schedule
bought seven days late and then set to seven days. The second purchase re-anchors on today, so the
edit yields one extra purchase rather than a loop.

**Decided: documentation only.** Only the owner can trigger it, on their own schedule, for a purchase
bounded by the schedule balance. A guard that refuses a period making the schedule immediately due
would also refuse ordinary mid-cycle shortening (monthly to weekly ten days after a buy); enforcing
the property exactly would need a stored last-purchase day on the purchase path.

### 3. `SovrynHandler` had no underlying-token check

`LayerBankHandler` verifies `aToken.UNDERLYING_ASSET_ADDRESS()` at construction. The Sovryn adapter
accepted any iToken; a mismatch failed closed on the first deposit, after assignment to a route that
can never be reassigned. The getter was verified on-chain, not assumed:

| Token | Network | Call | Result |
|---|---|---|---|
| iSUSD `0xd8D2…93c1` | Rootstock mainnet | `loanTokenAddress()` | DOC `0xe700…D9Db` |
| iSUSD `0x74e0…d89f` | Rootstock testnet | `loanTokenAddress()` | DOC `0xCB46…Dae0` |
| iSUSD (mainnet) | | `underlying()`, `asset()`, `UNDERLYING_ASSET_ADDRESS()` | revert (`LoanTokenLogicProxy:target not active`) |
| kDOC `0x544E…fDa2` / `0x71e6…3914` | mainnet / testnet | `underlying()` | DOC on each |

`src/tropykus-legacy/` was outside the review but has the same gap, so it gets the same check.

The error is shared. All three adapters now make the same claim about their receipt token, so it is
one `LendingHandler__UnderlyingMismatch()` on `ILendingHandler` rather than one error per protocol;
`LayerBankHandler__UnderlyingMismatch()` is renamed into it. The check itself stays in each adapter's
constructor because only the adapter knows its protocol's getter.

### 4. LayerBank redeem sizing assumes half-up `rayDiv`

The Pool has no share-sized withdraw, so `LayerBankHandler` picks the underlying amount whose burn is
exactly the `s` scaled shares debited: `floor(s × index / RAY)`, plus one wei when half-up `rayDiv` of
that floor gives `s − 1`. Upstream Aave v3 now burns with a ceiling
(`TokenMath.getATokenBurnScaledAmount` → `rayDivCeil`).

Measured on a chain-tip fork on 2026-10-02 (Pool `POOL_REVISION()` 7): the live LayerBank Pool still
burns **half-up**, on every sampled withdrawal, including the samples where half-up and round-up
differ. The sizing is correct for what is deployed.

Can one sizing be exact under both rules without touching the `LendingHandler` check? **No.** With
`r = RAY / index`, half-up burns `s` iff `a × r ∈ [s − ½, s + ½)` and round-up burns `s` iff
`a × r ∈ (s − 1, s]`. The overlap `[s − ½, s]` spans `1 / (2r)` wei of `a`, which is under one wei
whenever `index < 2 RAY`. When the floor lands below `s − ½`, half-up needs `floor + 1` and round-up
needs `floor`; no integer satisfies both. The rounding-agnostic alternative is two calls (withdraw the
floor, read `scaledBalanceOf`, withdraw one more wei if one share short). It adds an aToken read to
every redeem and a second Pool `withdraw` to roughly half of them, on the swapper-paid purchase path,
to cover an upgrade that fails closed. Declined: document the assumption and pin it with a live probe.

### 5. The purchase that uses a user's last shares can revert `InsufficientShares`

Investigated; no change. This is the tail [R39](./R39-remove-single-buy.md) raised and
[R43](./R43-dex-path-review.md) decided to keep (revert, do not clamp), pinned by
`BatchTailScheduleTest`. Two refinements to how it has been described:

- The shortfall is not always one share unit. Each purchase's ceiling over-debits a fraction of a
  unit, so after `N` purchases at an unchanged rate the last row is short by up to `N` units. Computed
  at a flat rate for a 25-token purchase: Sovryn DOC 1 / 3 / 15 units and LayerBank USDT0 1 / 8 / 42
  units for 1 / 10 / 52 purchases. A unit is about one wei of an 18-decimal token and `1e-6` of a
  6-decimal one, so the largest of those is 0.000042 USDT0.
- "Clears with any accrual" needs the rate to grow at all. On a market with no borrowers the rate is
  flat, and the last purchase then never executes; the owner exits the remainder through
  `withdrawToken`, which clamps to the share-backed amount.

**Recommendation: accept.** The ceil-debit / floor-value rounding is what keeps the sum of virtual
shares at or below the receipt shares held, and stays. Clamping the debit to the shares held would
make that row retrieve less than its planned gross while `PurchaseRbtc` allocates by planned weights,
moving the dust onto the other buyers in the batch, and would need a tolerance to tell dust from a
real shortfall. The bot already drops a row that fails simulation. The useful follow-up is off-chain:
the front end can tell a user whose last purchase is stuck to withdraw the remainder.

## Open product decisions

**none** (item 2 decided documentation-only; item 5 investigate-only)

## Scope

- [x] `AUDIT_GUIDE.md`: gross-to-venue, fee credited in rBTC from measured output, allocation
      formulas, exact gross consumption.
- [x] `AUDIT_GUIDE.md` and `IDcaManager.batchBuyRbtc` NatSpec: the one-buy-per-UTC-day rule is
      conditional on an unchanged period; describe the period-edit case.
- [x] `RbtcPurchaseTest.testLateBuyThenShorterPeriodIsDueAgainTheSameUtcDay` pins it.
- [x] `ILendingHandler.LendingHandler__UnderlyingMismatch()` replaces
      `ILayerBankHandler.LayerBankHandler__UnderlyingMismatch()`; `LayerBankHandler` reverts with it.
- [x] `SovrynHandler` constructor: revert it unless `iToken.loanTokenAddress() == stablecoin`.
      `IiSusdToken.loanTokenAddress()`.
- [x] `TropykusHandler` constructor: revert it unless `kToken.underlying() == stablecoin`.
      `IkToken.underlying()`.
- [x] Mocks expose the getters (`MockIsusdToken`, `MockKToken`, `MockKdocToken`).
- [x] `LayerBankHandler._protocolRedeem` NatSpec, `src/layerbank/README.md`, and `AUDIT_GUIDE.md`
      state the half-up assumption, the failure mode, and the monitoring step.
- [x] `LayerBankLivePoolProbe.test_livePool_withdrawBurnsHalfUpScaledShares` and
      `SovrynLiveITokenProbe` run in the chain-tip fork lanes.

## Out of scope

- [ ] Any change to the cadence code or to `updatePurchasePeriod`.
- [ ] Any change to `LendingHandler` rounding, the exact share-consumption check, or the tail revert.
- [ ] A mandatory gap between protected purchase windows (reported as an observation; a product
      decision under invariant 10, not assigned here).
- [ ] Two-call LayerBank redeem sizing.

## Files likely touched

`AUDIT_GUIDE.md`, `src/interfaces/IDcaManager.sol`, `src/interfaces/ILendingHandler.sol`,
`src/sovryn/SovrynHandler.sol`, `src/sovryn/IiSusdToken.sol`, `src/tropykus-legacy/TropykusHandler.sol`,
`src/tropykus-legacy/IkToken.sol`, `src/layerbank/LayerBankHandler.sol`,
`src/layerbank/ILayerBankHandler.sol`, `src/layerbank/README.md`, `test/mocks/MockIsusdToken.sol`,
`test/mocks/MockKToken.sol`, `test/mocks/MockKdocToken.sol`, `test/unit/RbtcPurchaseTest.t.sol`,
`test/unit/layerbank/LayerBankLivePoolProbe.t.sol`, `test/unit/sovryn/SovrynLiveITokenProbe.t.sol`,
`test/ai-generated/unit/sovryn/SovrynHandlerTest.t.sol`,
`test/ai-generated/unit/tropykus-legacy/TropykusHandlerTest.t.sol`,
`test/ai-generated/unit/layerbank/LayerBankHandlerTest.t.sol`.

## Required tests

- `make check`, `make fork-sovryn`, `make fork-layerbank`; `make fork-tropykus` because
  `src/tropykus-legacy/` changed.
- Assert: second same-day purchase after a late buy and a period cut succeeds, and is refused with
  the period unchanged; Sovryn and Tropykus constructors revert on a mismatched underlying; the live
  iSUSD answers `loanTokenAddress()` with DOC and refuses a USDRIF handler; the live LayerBank Pool
  burns half-up on samples that separate it from round-up.
- Fork-specific assertions: yes, the two live probes above.

## Success criteria

- [x] The guide and NatSpec match `PurchaseRbtc.batchBuyRbtc` and the cadence code.
- [x] A Sovryn handler cannot be constructed against another asset's iToken; deploy scripts and
      every lane still construct through the scripts unchanged.
- [x] The exact share-consumption check in `LendingHandler` is untouched.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold unless this spec explicitly changes one.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: one constructor-only error, `LendingHandler__UnderlyingMismatch()`, on every lending handler.
  It replaces `LayerBankHandler__UnderlyingMismatch()` on the LayerBank leaves and is new on the Sovryn
  (and legacy Tropykus) ones. A deployed handler can never raise it. No function, event, or storage
  change.
- Scripts: none. `DeployFinal` already passes the matching iSUSD and DOC.
- Cutover: `bitchill-monitoring` regenerates `abi.json` at cutover anyway; the renamed error is in
  every lending leaf's ABI
  ([bitchill-monitoring#10 comment](https://github.com/BitChillRSK/bitchill-monitoring/issues/10#issuecomment-5948821411)).
  Operations rerun `make fork-layerbank` when the LayerBank Pool or aToken implementation changes;
  the alert for that is [bitchill-monitoring#36](https://github.com/BitChillRSK/bitchill-monitoring/issues/36).
