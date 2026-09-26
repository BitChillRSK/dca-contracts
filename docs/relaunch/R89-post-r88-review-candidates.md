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
  - the lending `totalSharesToRedeem` sum: each debit is capped by that user's remaining booked
    shares, so the total is at most the shares the handler books, which its receipt balance backs.
    `_measuredProtocolRedeem` would also refuse any total the market did not burn exactly;
  - `totalPurchasedRbtc * plannedNet`: rBTC measured as received is below Rootstock's native supply
    (about `2⁸⁵` wei, the bound R87 used for `_creditRbtc`), times a `uint96` weight;
  - `totalStablecoinAmountToSpend * plannedNet`: the pipeline has just proved the handler's balance fell
    by exactly that amount, so it is at most the stablecoin's supply, times a `uint96` weight. This is
    the one bound that rests on a token property (supply below `2¹⁶⁰` base units) rather than on our own
    widths, and it feeds only `RbtcBought.amountSpent`. The review marked it optional; the human chose
    to include it.
  Divisions stay as they are: a zero divisor still panics inside `unchecked`.
- [x] **5. Off-purchase-path arithmetic of the same kind runs `unchecked`.** Found while implementing
  item 4, so they get their own commit:
  - `_lockedPrincipal`'s sum: each `tokenBalance` is `uint128`, and a user holds fewer than `2¹⁶`
    schedules per token, because `maxSchedulesPerToken` is a `uint16`;
  - the interest subtractions in `withdrawInterest` and `_accruedInterest`, which run only after the
    comparison that guards them;
  - the share credit in `_depositToken`: a user's booked shares are measured mint deltas less exact
    burns, so they are bounded by the receipt token's supply.
- [x] **6. `PurchaseUniswap` checks for a zero stablecoin once, in its constructor.** `i_stableToken` is
  immutable, but `_encodePurchasePath` re-checks it on every owner path call, and the constructor has
  to keep path encoding above its `decimals()` read so that check fires first. Check at the top of the
  constructor instead; the encoder uses `i_stableToken` directly and the ordering comment goes. The
  error and its selector do not change.
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
  for both allocation products. Each drives its block to the stated bound and compares it with
  full-width arithmetic.

## Results (2026-09-26)

Measured with `test/gas/R89ReviewCandidatesGas.t.sol` on each lane's script-deployed handler, on this
branch's head and on the parent PR's `src/` (`e557bd9`, #153) with the same test file. Rootstock
figures add 100 for every removed warm re-read, because Foundry charges 100 for it and Rootstock 200
([schedule](./ROOTSTOCK-GAS-SCHEDULE.md)). Everything else these items change is compute, which is
priced the same on both.

### Gas, `deploy` profile (ships)

| Path | Lane | Foundry before → after | Foundry Δ | Reads removed | Rootstock Δ |
|---|---|---:|---:|---:|---:|
| `batchBuyRbtc`, 10 rows | idle MoC (DOC) | 464,131 → 459,991 | −4,140 | 0 | **−4,140** |
| | Sovryn MoC (DOC) | 599,021 → 594,785 | −4,236 | 0 | **−4,236** |
| | LayerBank MoC (DOC) | 608,256 → 604,020 | −4,236 | 0 | **−4,236** |
| | idle Dex (USDRIF) | 497,263 → 493,090 | −4,173 | 0 | **−4,173** |
| | LayerBank Dex (USDRIF) | 641,622 → 637,470 | −4,152 | 0 | **−4,152** |
| `withdrawAllAccumulatedInterest`, one lending pair, 10 schedules | Sovryn MoC | 62,969 → 60,610 | −2,359 | 18 | **≈ −4,160** |
| | LayerBank MoC / Dex | 65,744 → 63,382 | −2,362 | 18 | **≈ −4,160** |
| `withdrawTokenAndInterest`, one schedule | Sovryn MoC | 124,309 → 124,097 | −212 | 3 | **≈ −510** |
| | LayerBank MoC | 132,341 → 132,123 | −218 | 3 | **≈ −520** |
| `withdrawToken`, lending | Sovryn MoC | 76,069 → 75,910 | −159 | 1 | **≈ −260** |
| | LayerBank MoC | 81,326 → 81,164 | −162 | 1 | **≈ −260** |
| `createDcaSchedule` | lending routes | 169,934 → 169,788 | −146 | 1 | **≈ −250** |
| | idle routes | 106,973 → 106,882 | −91 | 1 | **≈ −190** |

- **Batch.** Item 4 saves about 420 per row. A 10-row relaunch batch is about 1M on Rootstock (the gas
  audit's live fit, with its relaunch row), so that is about 0.4%, or about a cent at R87's
  conversion.
- **Removed reads per path.** In `withdrawAllAccumulatedInterest`, 17 are id-array re-reads (item 1)
  and one is the booked-shares re-read (item 2). `withdrawTokenAndInterest` removes two booked-shares
  re-reads and one id-array re-read. `withdrawToken` removes one booked-shares re-read, and
  `createDcaSchedule` one settings re-read (item 3).
- **More schedules, more saving.** `_lockedPrincipal`'s saving grows with the caller's schedule count:
  under `deploy` it removes N + (N − ⌈N/4⌉) reads for N schedules on the token, and under `default`
  it removes N. `topUpFromInterest` and the `getInterestAccrued` view run the same loop.
- **Item 5.** It is compute only (tens of gas per call) and is inside the non-batch figures above.

`default` profile, as same-build Foundry pins: 10-row batches −5,982 (idle) and −6,092 (lending);
`withdrawAllAccumulatedInterest` −810, with 11 reads removed there, because legacy codegen still reads
one id word per id; `withdrawTokenAndInterest` −321; `withdrawToken` −192; `createDcaSchedule` −99 (idle)
and −165 (lending).

### Read-count pins (per slot, `vm.startStateDiffRecording`)

| Pin | Before | After (`default`) | After (`deploy`) |
|---|---:|---:|---:|
| `_lockedPrincipal`, 10 ids: array length | 11 | 1 | 1 |
| `_lockedPrincipal`, 10 ids: id words (3 packed) | 10 | 10 | 3 |
| `withdrawToken`: the user's booked shares | 2 | 1 | 1 |
| `withdrawTokenAndInterest`: the user's booked shares | 4 | 2 | 2 |
| `createDcaSchedule`: the settings word | 3 | 2 | 2 |

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
| **Total** | **+255** | **+111** | **−110** | **−120** | **−106** | **−110** | **−93** | **−110** |

`default`: DcaManager +115, OperationsAdmin +185, every handler −103 to −145.

`via_ir` places code differently for item 2 on the LayerBank Dex leaf (+126), and item 4 more than
takes it back. Items 8 and 9 leave metadata-stripped runtime and creation code byte-identical on all
ten deployable contracts, under both profiles. The largest artifact, LayerBank Dex, ends at 13,077
bytes under `deploy`, far below EIP-170.

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
- [x] Any storage-layout, selector, or event change. The one ABI addition is item 7's custom error.

## Files likely touched

- `src/DcaManager.sol` (items 1, 3, 5)
- `src/LendingErc20Handler.sol` (items 2, 4, 5)
- `src/FeeHandler.sol` (item 4)
- `src/idle/IdleErc20Handler.sol` (item 4)
- `src/PurchaseRbtc.sol` (items 4, 8)
- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol` (item 6)
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`, `src/interfaces/IStablecoinSource.sol`
  (new), `src/interfaces/ITokenHandler.sol`, `src/interfaces/IPurchaseRbtc.sol`, `src/StablecoinSource.sol`
  (item 7)
- `src/interfaces/IDcaManager.sol` (item 8)
- `src/interfaces/IStablecoin.sol` (item 9, deleted)
- `test/unit/LendingErc20HandlerRedeemTest.t.sol` (item 2 harness call)
- `test/unit/ZeroTokenPurchaseUniswapTest.sol` (item 6 wording)
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
- Item 6: `PurchaseUniswapZeroTokenTest` still expects `PurchaseUniswap__ZeroPurchaseToken`.
- Item 4: bound tests at `type(uint96).max` amounts, the 500 bps cap, rBTC at `2⁸⁵`, and a delivered
  stablecoin total of `2¹⁶⁰ − 1`, each checked against full-width arithmetic (`Math.mulDiv` for the
  products).
- No fork-specific assertions are added.

## Success criteria

- [x] Items 1–10 are implemented, one commit each, and nothing from **Out of scope** ships.
- [x] Read-count pins show items 1–3 removing the reads listed under **Results**, on both profiles.
- [x] Every `unchecked` block states its bound in a source comment. The item 4 blocks that rest on a width
  or a supply (the fee loops, the idle sum, both allocation products) are tested at that bound against
  full-width arithmetic. The lending sum is also re-checked at run time, because the market must burn
  exactly that total, and item 5's subtractions sit behind the comparison that guards them.
- [x] No selector, event, or storage-layout change; one new `OperationsAdmin` custom error.
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
  `PurchaseUniswap__ZeroPurchaseToken` now fires at the top of the constructor instead of during path
  encoding; its selector is unchanged.
- Scripts: none. Every deploy script already constructs each handler with the stablecoin it assigns,
  and the deployment tests prove it. Item 7 turns that into a property the contract enforces.
- Cutover: `bitchill-monitoring` should regenerate its `abi.json` for the new error. That goes as a
  comment on its running relaunch issue, following R47's new owner-only error. There is no other
  consumer surface.
