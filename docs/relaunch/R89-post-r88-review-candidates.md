# R89 — implement the post-R88 review candidates

Status: **implemented** · Assigned: yes · Optional/further-review: no

GitHub [#154](https://github.com/BitChillRSK/dca-contracts/pull/154), stacked on R88 ([#153](https://github.com/BitChillRSK/dca-contracts/pull/153)).

## Objective

Ship the gas and code-quality improvements found by a whole-protocol review after R88, and record every
candidate the review weighed and did not ship, with its reason. The bar is R87's: a change that removes a
redundant read, check, or file may land at any size when its bound is explicit and tested; a change that
adds complexity needs about 1% of a batch and real money behind it.

## Background

The review covered every first-party `src/` file except `src/tropykus-legacy/`, which no live deploy
branch builds. Method:

- Per-slot storage accesses via `vm.startStateDiffRecording`, on the `deploy` (`via_ir`) profile that
  ships. A read that survives the IR optimizer is a real `SLOAD`; one it merges is not a finding.
- Gas on both profiles, converted to Rootstock with
  [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). A removed warm re-read is 100 in Foundry
  and 200 on Rootstock, so each adds 100 to the Foundry delta. Compute-only changes carry over 1:1.
- A throwaway harness with idle, Sovryn, and LayerBank MoC routes plus an idle Dex route, 10-row
  batches, flat and variable fees. The retained version is `test/gas/R89ReviewCandidatesGas.t.sol`.

Anything R87, R88, or an earlier spec already decided was excluded from the candidate list up front
(see **Already decided**). The purchase path proved clean of redundant reads under `via_ir`: the Dex
handler reads 20 distinct slots once each, and the only repeat is the slot-0 read-modify-write the audit
closed.

## Open product decisions

**None.** Decided 2026-09-26 by the human after reading the review: implement every candidate the review
recommended, including the ones it marked optional and the `assignTokenHandler` hardening it marked as
outside the gas/code-quality brief, and record the rest here.

## Scope

One commit per item.

- [x] **1. `_lockedPrincipal` copies the id array to memory.** It walks a `uint64[] storage`, so every
  `scheduleIds[i]` re-reads the length for the bounds check and re-reads the packed word: 1 + 2N reads
  where 1 + ⌈N/4⌉ suffice. The storage pointer, and the comment "without copying the schedule array",
  date from before R64, when the array held whole `DcaDetails` structs. Change the one keyword and fix
  the comment.
- [x] **2. `_redeemShares` takes the shares its callers already loaded.** `withdrawInterest` and
  `_withdrawToken` read `s_shares[user]` and `_redeemShares` reads it again; `via_ir` keeps both reads.
  Pass the value in, as `_setUserShares(previousShares)` already does. Update the one test-harness call.
- [x] **3. `_validatePurchasePeriod` takes the minimum.** It re-reads `s_protocolSettings`, which makes
  the "One load of the packed scalars" comment in `createDcaSchedule` untrue. Create passes
  `settings.minPurchasePeriod`; update passes a direct read. The revert order does not change.
- [x] **4. Purchase-path arithmetic that cannot overflow runs `unchecked`.** Each bound follows from a
  width or a cap the code already enforces:
  - fee-loop sums (`aggregatedFee`, `totalAmountToSpend`), flat and variable: each row is a schedule's
    `uint96` purchase amount, so a sum is below `n · 2⁹⁶`;
  - `amount * feeRate` in `_calculateFeeAtRate`: below `2⁹⁶ · MAX_FEE_RATE_CAP`;
  - the idle `totalWithdrawn` sum: below `n · 2⁹⁶`;
  - `totalPurchasedRbtc * plannedNet`: rBTC measured as received is below Rootstock's native supply
    (about `2⁸⁵` wei, the bound R87 used for `_creditRbtc`), times a `uint96` weight.
  Divisions stay as they are: a zero divisor still panics inside `unchecked`. The first push also made
  the lending `totalSharesToRedeem` sum and the `amountSpent` product unchecked; review put both back
  (see **Review follow-up**).
- [x] **5. Off-purchase-path arithmetic of the same kind runs `unchecked`.** Found while implementing
  item 4, so they get their own commit:
  - `_lockedPrincipal`'s sum: each `tokenBalance` is `uint128`, and a user holds fewer than `2¹⁶`
    schedules per token, because `maxSchedulesPerToken` is a `uint16`;
  - the interest subtractions in `withdrawInterest` and `_accruedInterest`, which run only after the
    comparison that guards them.
  The first push also made `_depositToken`'s share credit unchecked; it is checked again for the same
  reason as the lending sum (see **Review follow-up**).
- [x] **6. `PurchaseUniswap` checks for a zero stablecoin once, in its constructor.** `i_stableToken` is
  immutable, but `_encodePurchasePath` re-checks it on every owner path call, and the constructor has
  to keep path encoding above its `decimals()` read so that check fires first. Check at the top of the
  constructor instead; the encoder uses `i_stableToken` directly and the ordering comment goes. The
  error and its selector do not change here; item 13 then moves the check to `StablecoinSource`.
- [x] **7. `assignTokenHandler` refuses a handler built for another stablecoin.** Assignment is add-only
  and burns the handler address (R47), so one mistyped `token` permanently occupies a `(token, route)`
  pair with a handler that would pull a different stablecoin from depositors. This is the same kind of
  one-argument, permanent mistake R13/R31 closed for route class. The deploy tests check each script's
  handler (`FinalDeploymentTest` and the add-on deployment tests), but an owner's later manual
  assignment is not checked on chain. Read `i_stableToken()` from the handler and revert with a new
  `OperationsAdmin__HandlerTokenMismatch(token, handler)`.
  - The getter joins the handler interface, as R70 did for `IDcaManager.i_operationsAdmin()`, so any
    contract that implements `ITokenHandler` must also answer the check, and `OperationsAdmin` calls it
    through `ITokenHandler`, not through the abstract `StablecoinSource`.
  - It is declared on a new `IStablecoinSource`, which `ITokenHandler` extends and `StablecoinSource`
    implements, not in `ITokenHandler` itself. `TokenHandler` inherits both `ITokenHandler` and
    `StablecoinSource`, and solc (error 6480) refuses two unrelated bases that both define the getter
    when one of them is a public state variable, which cannot be overridden. The purchase side
    (`PurchaseRbtc`) reads the same immutable, so it stays on `StablecoinSource`.
  - `IPurchaseRbtc` extends `IStablecoinSource` too. `PurchaseRbtc` spends that stablecoin, so its
    interface names it, and the inheritance graph requires it: `TokenHandler` reaches
    `IStablecoinSource` through its least-derived base (`ITokenHandler`) and `PurchaseRbtc` through its
    most-derived one (`StablecoinSource`), so every leaf fails C3 linearization (solc error 5005) until
    both halves reach it through their interface.
  - Every handler already exposed `i_stableToken()`; only the two interfaces' ABIs list it now.
  - `type(ITokenHandler).interfaceId` counts only the functions an interface declares itself, so the
    ERC-165 id does not change. It would not have mattered before relaunch either: handlers and
    `OperationsAdmin` compute the id from the same source and ship together (R54 changed
    `ITokenLending`'s id on that basis), and no consumer repo hardcodes it.
  - *Revised after the first push.* The first version called the getter through `StablecoinSource` and
    kept it off the interface to preserve the ERC-165 id, which is not a constraint before relaunch.
- [x] **8. Stale idle-ledger NatSpec.** R87 removed the idle ledger, but two comments still describe it:
  - `IDcaManager.withdrawToken`'s `@dev` still says an idle route "pays short only if the handler's own
    ledger disagrees", and `@inheritdoc` carries that sentence into the verified `DcaManager`;
  - `PurchaseRbtc.batchBuyRbtc`'s `@dev` still says the idle handler "reverts rather than
    under-deliver", which described the deleted `InsufficientIdleBalance` revert.
- [x] **9. Delete the resurrected `src/interfaces/IStablecoin.sol`.** R61 (`430cfbd`) moved it to
  `test/interfaces/`. `938f86b`, a DcaManager header-docs commit, re-added it by accident, and R72 then
  relicensed the stray copy. Nothing in `src/` or `script/` imports it, and the mocks import the test
  copy.
- [x] **10. Retained evidence.** Add `test/gas/R89ReviewCandidatesGas.t.sol`, built on `DcaDappTest`
  so it measures each lane's script-deployed handler. It pins per-slot read counts for items 1–3 and
  logs the lane's 10-row batch for item 4. Add bound tests to the suites that already own each harness:
  `FeeHandlerTest` for the fee loops, `IdleErc20HandlerTest` for the idle sum, and `PurchaseRbtcTest`
  for the rBTC allocation product. Each drives its block to the stated bound and compares it with
  full-width arithmetic.
- [x] **11. `assignTokenHandler` reads the route class once.** It reads `s_routeClass[route]` for the
  registration check and again for the lending/idle split. The `supportsInterface` calls between them
  keep `via_ir` from merging the two, so the second is a real `SLOAD` (200 on Rootstock). Load it into a
  local once. The checks and their order do not change. Found in review.
- [x] **12. Two widening adds in `DcaManager` run `unchecked`.** Both overflow checks survive `via_ir`
  and can never fire. Found in review.
  - `uint256(settings.scheduleNonce) + 1` in `createDcaSchedule` adds one to a widened `uint64`. The
    `toUint64()` around it stays, so nonce exhaustion still reverts (R50).
  - `block.number + PROTECTED_PURCHASE_WINDOW_BLOCKS` in `activateProtectedPurchaseWindow` adds 5 to a
    block height.
- [x] **13. `StablecoinSource` rejects a zero stablecoin.** It stores `i_stableToken` for every
  handler, but only `PurchaseUniswap` refused a zero one. Found in the owner's review (2026-09-27).
  - Before this item, only the idle Dex leaf reached that check, and the idle MoC leaf deployed with a
    zero stablecoin. The lending leaves' constructors run before `PurchaseUniswap`'s, so they failed on
    the token or the market instead. Sovryn's approval reverted with
    `SafeERC20FailedOperation(address(0))`, and LayerBank's underlying check with
    `LayerBankErc20Handler__UnderlyingMismatch()`.
  - Item 7 already stops such a handler from being assigned, since its `i_stableToken()` cannot equal
    an accepted token. So this is a deploy-time diagnostic, not a new guard.
  - The check moves into `StablecoinSource`'s constructor as `StablecoinSource__ZeroStablecoin()`,
    declared on `IStablecoinSource`. `PurchaseUniswap__ZeroPurchaseToken` goes.
  - Only constructors change, so runtime code should not move.
  - `ZeroTokenPurchaseUniswapTest` tested the old check through a test-only contract whose constructor
    always reverts. That needs a `via_ir` exemption in `foundry.toml` (solc error 1284, R60). A test
    that deploys each production leaf with a zero stablecoin replaces it, and the exemption goes.

## Review follow-up (2026-09-26)

An external review of the first push raised four points. All four are accepted.

1. **The `amountSpent` product is checked again.** Its bound was the stablecoin's supply being below
   `2¹⁶⁰` base units, which no code enforces for a stablecoin listed later. A wrap would publish a
   wrong `RbtcBought.amountSpent` without failing, and the check costs tens of gas per row. The rBTC
   product stays unchecked: Rootstock's native supply is a hard bound.
2. **The lending `totalSharesToRedeem` sum is checked again, and so is `_depositToken`'s share credit.**
   - The review corrected this spec: an exact-burn check would not catch a wrapped total, because the
     market would be asked to burn the wrapped value and would burn exactly that.
   - The real bound on both is that booked shares sum to measured receipt-token mints less exact
     burns, so the handler's receipt balance backs them. That rests on the lending market's receipt
     token behaving. This spec already refuses `unchecked` math on market-derived values (see
     **Considered, not implemented**): a market that malfunctions must revert, not wrap.
   - The review named only the batch sum. The deposit credit rests on the same backing, so it goes
     back too.
3. **Two missed candidates are implemented** as items 11 and 12. The review's cached route class and
   two `unchecked` widening adds each remove a check or read that can never matter.
4. **A duplicated `@dev` line in `PurchaseRbtcTest.t.sol`**, introduced by item 10's test commit, is
   removed.

## Results (2026-09-26)

Measured with `test/gas/R89ReviewCandidatesGas.t.sol` on each lane's script-deployed handler, on this
branch's head and on the parent PR's `src/` (`e557bd9`, #153) with the same test file. Rootstock
figures add 100 for every removed warm re-read, because Foundry charges 100 for it and Rootstock 200
([schedule](./ROOTSTOCK-GAS-SCHEDULE.md)). Everything else these items change is compute, which is
priced the same on both.

### Gas, `deploy` profile (ships)

| Path | Lane | Foundry before → after | Foundry Δ | Reads removed | Rootstock Δ |
|---|---|---:|---:|---:|---:|
| `batchBuyRbtc`, 10 rows | idle MoC (DOC) | 464,131 → 460,336 | −3,795 | 0 | **−3,795** |
| | Sovryn MoC (DOC) | 599,021 → 596,085 | −2,936 | 0 | **−2,936** |
| | LayerBank MoC (DOC) | 608,256 → 605,320 | −2,936 | 0 | **−2,936** |
| | idle Dex (USDRIF) | 497,263 → 493,843 | −3,420 | 0 | **−3,420** |
| | LayerBank Dex (USDRIF) | 641,622 → 638,769 | −2,853 | 0 | **−2,853** |
| `withdrawAllAccumulatedInterest`, one lending pair, 10 schedules | Sovryn MoC | 62,969 → 60,607 | −2,362 | 18 | **≈ −4,160** |
| | LayerBank MoC / Dex | 65,744 → 63,382 | −2,362 | 18 | **≈ −4,160** |
| `withdrawTokenAndInterest`, one schedule | Sovryn MoC | 124,309 → 124,091 | −218 | 3 | **≈ −520** |
| | LayerBank MoC | 132,341 → 132,123 | −218 | 3 | **≈ −520** |
| `withdrawToken`, lending | Sovryn MoC | 76,069 → 75,907 | −162 | 1 | **≈ −260** |
| | LayerBank MoC | 81,326 → 81,164 | −162 | 1 | **≈ −260** |
| `createDcaSchedule` | every lane | 169,934 → 169,821 (Sovryn MoC) | −113 | 1 | **≈ −210** |
| `activateProtectedPurchaseWindow` | every lane | 35,067 → 35,046 | −21 | 0 | **−21** |
| `assignTokenHandler` (owner) | every lane | 50,391 → 50,922 (Sovryn MoC) | +501 to +707 | 1 | **≈ +1,000 to +1,210** |

- **Batch.** Item 4 saves about 285–380 per row. A 10-row relaunch batch is about 1M on
  Rootstock (the gas audit's live fit, with its relaunch row), so that is about 0.3–0.4%, under a cent
  at R87's conversion.
- **What the review follow-up gave back.** Against the first push, a 10-row batch costs 345–753 more
  on idle routes and about 1,300 more on lending routes. Reverting each restored check on its own, on
  the same build:
  - the `amountSpent` product costs 345 on idle MoC, 753 on idle Dex (its only restored check), and
    750 on Sovryn MoC and LayerBank Dex;
  - the lending sum costs 550.
  The deposit share credit is off the batch path; its check costs tens of gas per lending deposit.
- **Removed reads per path.** In `withdrawAllAccumulatedInterest`, 17 are id-array re-reads (item 1)
  and one is the booked-shares re-read (item 2). `withdrawTokenAndInterest` removes two booked-shares
  re-reads and one id-array re-read. `withdrawToken` removes one booked-shares re-read,
  `createDcaSchedule` one settings re-read (item 3), and `assignTokenHandler` one route-class re-read
  (item 11).
- **`assignTokenHandler` costs more overall.** Item 7's `i_stableToken()` is a third call into the same
  handler. That is 700 on Rootstock against Foundry's 100, and item 11's saved read (200) comes off it.
  It is owner-only, once per token-route pair.
- **More schedules, more saving.** `_lockedPrincipal`'s saving grows with the caller's schedule count:
  under `deploy` it removes N + (N − ⌈N/4⌉) reads for N schedules on the token, and under `default`
  it removes N. `topUpFromInterest` and the `getInterestAccrued` view run the same loop.
- **Items 5 and 12.** Compute only, tens of gas per call, and inside the figures above.
  `createDcaSchedule` saves the same on every route: now that the deposit credit is checked again, only
  items 3 and 12 touch it.

`default` profile, as same-build Foundry pins:
- 10-row batches: −4,812 (idle) and −4,172 (lending);
- `withdrawAllAccumulatedInterest`: −810, with 11 reads removed there, because legacy codegen still
  reads one id word per id;
- `withdrawTokenAndInterest` −321, `withdrawToken` −192, `createDcaSchedule` −168,
  `activateProtectedPurchaseWindow` −78;
- `assignTokenHandler`: +536 to +647.

### Read-count pins (per slot, `vm.startStateDiffRecording`)

| Pin | Before | After (`default`) | After (`deploy`) |
|---|---:|---:|---:|
| `_lockedPrincipal`, 10 ids: array length | 11 | 1 | 1 |
| `_lockedPrincipal`, 10 ids: id words (3 packed) | 10 | 10 | 3 |
| `withdrawToken`: the user's booked shares | 2 | 1 | 1 |
| `withdrawTokenAndInterest`: the user's booked shares | 4 | 2 | 2 |
| `createDcaSchedule`: the settings word | 3 | 2 | 2 |
| `assignTokenHandler`: the route's class | 2 | 1 | 1 |

The before column is the same on both profiles. Two reads of the settings word remain after the
change: the one load, and the read inside the nonce's read-modify-write. The latter is the compiler's
packed-field write, which the gas audit closed.

### Runtime size (bytes, metadata included), per commit

`deploy`:

| Item | DcaManager | OperationsAdmin | Idle MoC | Idle Dex | Sovryn MoC | Sovryn Dex | LayerBank MoC | LayerBank Dex |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 `_lockedPrincipal` | +254 | | | | | | | |
| 2 `_redeemShares` | | | | | +5 | +5 | +5 | +126 |
| 3 `_validatePurchasePeriod` | +11 | | | | | | | |
| 4 purchase-path `unchecked` | | | −110 | −88 | −91 | −63 | −78 | −184 |
| 5 off-path `unchecked` | −10 | | | | −20 | −20 | −20 | −20 |
| 6 zero-stablecoin check | | | | −32 | | −32 | | −32 |
| 7 handler/token match | | +111 | | | | | | |
| Review: three checks restored | | | +40 | +3 | +29 | +15 | +16 | +150 |
| 11 route class | | −23 | | | | | | |
| 12 widening adds | −14 | | | | | | | |
| **Total** | **+241** | **+88** | **−70** | **−117** | **−77** | **−95** | **−77** | **+40** |

`default`: DcaManager +98, OperationsAdmin +165, every handler −80 to −124.

`via_ir` lays out the LayerBank Dex leaf differently for item 2 (+126) and for the restored checks
(+150). Item 4 takes back only part of that, so that leaf ends 40 bytes above #153 under `deploy`.
Items 8 and 9 leave metadata-stripped runtime and creation code byte-identical on all ten deployable
contracts, under both profiles. So does item 7's revision, which moved the getter onto
`IStablecoinSource`: it changes types, not code, so it adds no row. The largest artifact, LayerBank Dex,
ends at 13,227 bytes under `deploy`, far below EIP-170's 24,576.

## Considered, not implemented

| Candidate | Evidence | Why not |
|---|---|---|
| Drop the `purchaseToken` local in `batchBuyRbtc` and use `i_stableToken` directly | `deploy` gas identical; runtime **+121** bytes on `LayerBankErc20HandlerDex` (`deploy`), **+155** (default) | Reads slightly cleaner but grows the artifact that ships and saves nothing. This is the size-regression reason R88 used to reject the shared scale declaration. |
| Pass the batch's gross total into `_batchRetrieveStablecoin` so idle need not re-sum | After item 4, the idle sum costs tens of gas per batch | Changes the hook signature, which R87 declined to change, for tens of gas. |
| Remove the length re-reads in `deleteDcaSchedule`'s swap-pop | A few hundred gas on a rare user call | Needs assembly or a memory round trip that costs more than it saves. Deletion's writes are already closed by the gas audit. |
| Pack `s_mocOracle` beside the Dex slippage settings | One `SLOAD` (200 on Rootstock) per Dex batch, under 0.1% | A storage-layout change across four Dex leaves for a single read. |
| Fold `IdleErc20Handler` into `TokenHandler`, or move `FeeHandler` out of `TokenHandler` | No state, check, or read removed | Inheritance plumbing with no gain. This is the reasoning R88 used to reject a shared handler core. |
| `unchecked` exchange-rate and oracle arithmetic (`TokenLending` share conversions, LayerBank's ray division, the Uniswap oracle floor) | Would save a check per call | These inputs come from a market or an oracle. If a market malfunctions it must revert, not wrap, and this repo controls no bound on them. |
| `unchecked` balance deltas that can fall (`TokenHandler` deposit/withdraw, `_measuredProtocolRedeem`'s cash delta, the Uniswap WRBTC delta) | Would save a check per call | The checked subtraction is what refuses a balance that fell across the call. Where a guard already exists (MoC's native delta, the exact-consumption comparisons), the subtraction is already `unchecked`. |
| `unchecked` `requested +=` in the lending zero-cash path | Runs only on a path that reverts | Saves nothing. |
| `unchecked` `amountSpent` product (shipped in the first push, reverted) | Tens of gas per row | Its bound is a stablecoin supply below `2¹⁶⁰`, which nothing enforces for a later listing, and a wrap would publish a wrong event field silently. |
| `unchecked` lending `totalSharesToRedeem` sum and `_depositToken` share credit (shipped in the first push, reverted) | Tens of gas per row or deposit | Their bound is that the market's receipt token backs the booked shares. That is a market property, and a malfunctioning market must revert, not wrap. |

### Already decided (not reopened)

- The zero-token guard in `createDcaSchedule` ([R64](./R64-batch-calldata-and-schedule-keying.md)).
- `depositToken`'s inner `toUint128`, pinned by
  `SchedulePackingTest.testDepositRevertsUint128MaxPlusOneBeforeTokensMove`
  ([R18](./R18-storage-packing.md)).
- An unchecked cadence-anchor downcast; unchecked truncation is out of scope under R18 and R50.
- Merging `TokenLending` into `LendingErc20Handler` ([R28](./R28-lending-erc20-handler.md)).
- Merging `getAccruedInterest` into `quoteAccruedInterest`, and the `_exchangeRate` hook
  ([R54](./R54-schedule-top-up-from-interest.md), [R88](./R88-post-r87-structural-cleanups.md)).
- The purchase row's slot-0 read-modify-write ([R81](./R81-one-write-per-packed-slot.md), gas audit).
- The fee-setter writes (R81), the `memory` path setters (R86), and the two `OperationsAdmin` reads (R84).
- The event fields, the fee sweep, balance reuse, and `optimizer_runs`
  ([R87](./R87-deferred-gas-candidates.md)).
- Unused members of vendored interfaces (`AGENTS.md`).

## Out of scope

- [x] Any candidate in **Considered, not implemented** or **Already decided**.
- [x] Assembly anywhere in the purchase path (invariant 5).
- [x] Any storage-layout, selector, or event change. The ABI changes are item 7's custom error and item
  13's swap of one constructor error for another.

## Files likely touched

- `src/DcaManager.sol` (items 1, 3, 5, 12)
- `src/LendingErc20Handler.sol` (items 2, 4, 5)
- `src/FeeHandler.sol` (item 4)
- `src/idle/IdleErc20Handler.sol` (item 4)
- `src/PurchaseRbtc.sol` (items 4, 8)
- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol` (items 6, 13)
- `src/OperationsAdmin.sol` (items 7, 11), `src/interfaces/IOperationsAdmin.sol`, `src/interfaces/IStablecoinSource.sol`
  (new), `src/interfaces/ITokenHandler.sol`, `src/interfaces/IPurchaseRbtc.sol`, `src/StablecoinSource.sol`
  (item 7)
- `src/interfaces/IDcaManager.sol` (item 8)
- `src/interfaces/IStablecoin.sol` (item 9, deleted)
- `test/unit/LendingErc20HandlerRedeemTest.t.sol` (item 2 harness call)
- `test/unit/ZeroTokenPurchaseUniswapTest.sol` (item 6 wording; deleted by item 13)
- `src/StablecoinSource.sol`, `src/interfaces/IStablecoinSource.sol`, `test/unit/ZeroStablecoinTest.t.sol`
  (new), `test/unit/PurchaseUniswapSettingsTest.sol` (a pointer comment), `foundry.toml` (the
  exemption), `README.md` (which names the exempt file) (item 13)
- `test/unit/OperationsAdminTest.t.sol`, `test/gas/StubPurchaseHandler.sol`, any test that assigns a
  handler under a token it was not built for, and any test stub that implements `ITokenHandler` (item 7)
- `test/gas/R89ReviewCandidatesGas.t.sol`, `test/ai-generated/unit/FeeHandlerTest.t.sol`,
  `test/ai-generated/unit/idle/IdleErc20HandlerTest.t.sol`, `test/unit/PurchaseRbtcTest.t.sol` (item 10)
- `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`,
  `docs/relaunch/ROOTSTOCK-GAS-AUDIT.md`

## Required tests

- `make check` and `make check-deploy`: item 4's `unchecked` blocks change the `via_ir` artifact that
  ships, so the default profile alone does not prove them.
- `make fork-sovryn` and `make fork-tropykus` before push.
- `forge test --match-path test/gas/R89ReviewCandidatesGas.t.sol -vv`, on default and
  `FOUNDRY_PROFILE=deploy`.
- Item 7: a mismatched stablecoin reverts with the new error, and a handler with no `i_stableToken()`
  still reverts. The error-precedence tests keep their order: code, class, and ERC-165 checks fire first.
- Item 13: each of the six production leaves, deployed with a zero stablecoin, reverts with
  `StablecoinSource__ZeroStablecoin`, under both profiles. With the exemption gone, `make check-deploy`
  compiles every test file but `LayerBankErc20HandlerDexTest.t.sol` under `via_ir`.
- Item 4: bound tests at `type(uint96).max` amounts, the 500 bps cap, and rBTC at `2⁸⁵`, each checked
  against full-width arithmetic (`Math.mulDiv` for the rBTC product).
- Item 11: a read-count pin on `s_routeClass[route]` during `assignTokenHandler`, on every lane.
- Item 12: the existing nonce-cap test still reverts at `type(uint64).max`, and the protected-window
  tests pass unchanged.
- No fork-specific assertions are added.

## Success criteria

- [x] Items 1–13 are implemented, one commit each, and nothing from **Out of scope** ships.
- [x] Read-count pins show items 1–3 and 11 removing the reads listed under **Results**, on both
  profiles.
- [x] Every `unchecked` block this PR adds either sits right below the comparison that guards it (item
  5's subtractions) or states its bound in a source comment. The item 4 blocks that rest on a width or
  a supply (the fee loops, the idle sum, the rBTC allocation product) are tested at that bound against
  full-width arithmetic. No `unchecked` block rests on a lending market's or a stablecoin's behavior.
- [x] No selector, event, or storage-layout change. One new `OperationsAdmin` custom error, and one
  constructor error renamed and moved to `StablecoinSource`.
- [x] Every figure under **Results** names its schedule (Foundry or Rootstock) and its profile.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold. Invariant 5 (no assembly in the purchase path),
  invariant 11 (the lending sum still has to equal the measured burn), invariant 12 (the exact
  consumption check still runs before the allocation products), and invariant 13 (`_creditRbtc` is
  untouched).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No gas claim comes from source shape alone.

## ABI / deploy / cutover impact

- ABI: one new custom error, `OperationsAdmin__HandlerTokenMismatch(address token, address handler)`,
  reachable only from owner-only `assignTokenHandler`. No selector, event, or storage-layout change.
  The `ITokenHandler` and `IPurchaseRbtc` interface ABIs now list `i_stableToken()`, which every
  handler already exposed, so no deployed contract's ABI changes and `ITokenHandler`'s ERC-165 id
  does not move.
  Item 13 replaces `PurchaseUniswap__ZeroPurchaseToken()` with `StablecoinSource__ZeroStablecoin()`.
  Both are constructor-only, so no transaction to a deployed contract can return either.
- Scripts: none. Every deploy script already constructs each handler with the stablecoin it assigns,
  and the deployment tests prove it. Item 7 turns that into a property the contract enforces.
- Cutover: `bitchill-monitoring` should regenerate its `abi.json` for the new error and the swapped
  constructor error. That goes as a comment on its running relaunch issue, following R47's new
  owner-only error. There is no other
  consumer surface.
