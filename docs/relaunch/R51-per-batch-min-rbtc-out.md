# R51 — Per-batch minimum rBTC output

Status: **implemented** · GitHub [#103](https://github.com/BitChillRSK/dca-contracts/pull/103) · Assigned: yes · Optional/further-review: no

PR 50 of the relaunch stack; GitHub implementation PR **[#103](https://github.com/BitChillRSK/dca-contracts/pull/103)**. Stack on R42's integration
follow-up (PR 49, [#101](https://github.com/BitChillRSK/dca-contracts/pull/101)). R52 owns dex-path
authorization and follows this PR; do not pull that surface into R51.

**This item deliberately reopens the R9 ABI freeze before relaunch.** PR 101 already changed both
swapper entry points to consume `IDcaManager.Batch`. R51 only appends one field to that existing tuple;
it does not re-decide or re-implement the struct-shaped one-handler call. R9's indexing rules and R10's
natspec standard apply to every surface added here.

## Objective

Let the swapper attach an absolute minimum rBTC output to each handler batch. The handler enforces it
against measured rBTC before crediting buyers. This caller-supplied bound can tighten, but can never
loosen, the governance-owned Uniswap oracle floor.

## Why this is relevant

The Uniswap floor is evaluated from the live MoC BTC/USD oracle at execution. It is the durable protocol
loss ceiling, but one number currently has to clear the route's LP fees and price impact while also
limiting pool-versus-oracle drift and sandwich loss. The live USDRIF route spends 0.35% in fee tiers
against the 0.5% default budget; USDT0 direct spends 0.3%. A quote-aware bot can set a tighter bound from
the actual pool state after those route costs are already reflected in the quote.

The new bound protects an honestly operated bot from stale composition and adverse pool execution. It is
**not** a new defense against a compromised swapper: the contract permits `0`, and even a nonzero rule
could be bypassed with `1`. A compromised key remains bounded by governance's oracle floor. State that
threat model in the PR rather than describing `minRbtcOut` as a second governance ceiling.

The check belongs in `PurchaseRbtc`, not `PurchaseUniswap`: both the accounting input and the output bound
must use the measured cash returned by `_purchaseRbtc`. It therefore works for MoC too, without treating
an integrator return value or a view as cash.

## Settled decisions

**No open contract-implementation decisions.** Implement these choices; the one-time live backstop values
are a measured relaunch/cutover decision, not a reason to stall PR 103.

1. Append `uint256 minRbtcOut` as the final field of the existing `IDcaManager.Batch`. It is the minimum
   aggregate output for that one handler batch, in **WRBTC/native rBTC wei (18 decimals)**. Stablecoin
   decimals affect the quote input, never the units of this field.
2. Permit `minRbtcOut == 0`. It exactly preserves the oracle-floor-only behavior and lets MoC ship before
   an off-chain MoC redemption preview exists. The production bot must nevertheless send a meaningful
   nonzero quote-derived value for every Dex batch, even when the governance floor happens to be stricter;
   that is an off-chain relaunch gate below.
3. PR 103 keeps `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT = 99.5%` and the 95% safety floor as source defaults; it
   does not pretend that 99.5% has already been proven as the right live setting for every route and batch
   size. Before relaunch, governance approves one durable per-handler backstop from the multi-observation
   calibration below. It must be the **highest (tightest) percentage** that clears the measured supported
   operating envelope after adding only quantified operational headroom for quote age and observed drift.
   Record that headroom and the resulting maximum oracle-relative loss in basis points; do not round down for
   convenience. If the required value exceeds the approved loss budget, keep the route disabled and improve
   its path/batching rather than silently falling back toward 95%. This is a one-time cutover setting—not a
   value the Safe or bot adjusts each week. The bot can never lower it; routine execution uses the dynamic
   caller bound.
4. Compare against the measured aggregate rBTC after the existing zero-output check and before any buyer
   credit or success event. Equality succeeds. A failure reverts the venue call, fee transfer, lending
   redemption, DcaManager schedule debits/timestamps, and every earlier handler in an across-handlers call.
5. Keep the bounds independent in authority and implementation. Do not pass `minRbtcOut` into
   `IV3SwapRouter.ExactInputParams`, and do not replace the governance calculation with a caller value.
   The router floor may revert first; otherwise the shared measured-output check applies.
6. Do not add a deadline. The caller minimum bounds the unfavorable quantity directly; a handler-created
   deadline is tautological, and a second caller field is not justified.
7. Keep the swapper bot as the sole signing service. Reuse or extract the route simulation logic from
   `rsk-uniswap-pools`; do **not** give the research/quote process a second copy of the swapper private key.
   A library or read-only quote sidecar is acceptable, but only the bot composes and signs transactions.

## Current baseline and implementation constraint

PR 101 already takes `Batch calldata` in both DcaManager entry points and `_batchBuyRbtc`; there is no
seven-argument DcaManager stack problem left for R51. Current `[profile.default]` runtime sizes are:

| Contract | baseline | EIP-170 margin |
|---|---:|---:|
| `DcaManager` | 23,683 | 893 |
| `LayerBankErc20HandlerDex` | 23,418 | 1,158 |
| `SovrynErc20HandlerDex` | 22,958 | 1,618 |
| `TropykusErc20HandlerDex` | 23,214 | 1,362 |
| `OperationsAdmin` | 6,123 | 18,453 |

`PurchaseRbtc.batchBuyRbtc` is already at the legacy-codegen stack limit: adding `minRbtcOut` was compiled
against PR 101 and produces `Stack too deep` under `via_ir = false`. Re-measure every handler and DcaManager;
do not copy the obsolete combined R51/R52 prototype figures.

**Correction recorded during implementation (2026-08-31).** This section originally required extracting the
per-buyer allocation/credit loop into a private `_creditBuyers` helper. That is **not** necessary and PR 103
does not do it. The function is exactly *one* slot over. PR 103 frees that slot by scoping `aggregatedFee` to
a block that ends once the fee is paid — it is dead from there on — which leaves room to keep both the loop
inline *and* the cached `uint256 numOfPurchases = buyers.length`. Measured against the helper, that is
87 gas cheaper on `testSinglePurchase`, 416 on `testBatchPurchasesOneUser`, and 17 bytes smaller on every Dex
handler, because it removes an internal call instead of adding one.

Two separate effects, measured separately so they are not confused. **The block scope is the larger win**:
with the loop inline and the length uncached either way, scoping `aggregatedFee` is worth −28 gas on
`testSinglePurchase` and −298 on `testBatchPurchasesOneUser`. **The cache is the smaller one**: measured
through `PurchaseRbtcHarness` at 1/2/5/20/50 rows it costs ~12 gas once per call and saves 3.00 gas per row
(one avoided `MLOAD` of the memory array's length word), so it breaks even at ~4 rows — −9 gas at one row,
+3 at five, +138 at fifty. Batches normally exceed four rows, so the cache stays; a one-row retry pays 9 gas
for it, which is not worth a second code path.

For the record, since it was checked rather than assumed: enabling the **legacy optimizer**
(`optimizer = true`, `via_ir = false`) does *not* relieve this. `[profile.default]` does leave the optimizer
off, but stack-too-deep persists with it on — solc's own message asks for `--via-ir` *while* enabling the
optimizer, and via-IR remains out of bounds for EIP-170 and deployment decisions under the toolchain rule in
[`IMPLEMENTATION_ORDER.md`](./IMPLEMENTATION_ORDER.md). Whether to turn the optimizer on at all is a separate
toolchain decision with its own item; it would change every deployed size (`DcaManager` 23,703 → 13,767 in a
measurement taken for that discussion) and the settings the Rootstock testnet proof and Blockscout
verification were made at.

## Scope

- [x] `IDcaManager.Batch` appends `uint256 minRbtcOut`, with natspec that fixes its aggregate semantics and
  WRBTC-wei units. `batchBuyRbtc(Batch)` and `batchBuyRbtcAcrossHandlers(Batch[])` keep their PR 101 shapes,
  but both selectors change because the tuple changes.
- [x] `DcaManager._batchBuyRbtc` forwards `batch.minRbtcOut` to the resolved handler. Preserve every PR 101
  check, effect, ordering decision, and one-handler retry path.
- [x] `IPurchaseRbtc.batchBuyRbtc` gains `uint256 minRbtcOut`.
- [x] `PurchaseRbtc.batchBuyRbtc` reverts
  `PurchaseRbtc__BelowSwapperMinimum(uint256 rbtcReceived, uint256 minRbtcOut)` when measured aggregate
  output is below the caller minimum, after the existing zero check and before credits.
- [x] Keep the per-buyer allocation/credit loop inline, freeing the one needed stack slot by scoping
  `aggregatedFee` to the block that pays the fee. (Originally specified as a `_creditBuyers` extraction; see
  the correction above.) Planned net amounts remain allocation weights; the denominator, truncation,
  accumulated-balance writes, per-row events, and the order of every call are unchanged.
- [x] Record final method selectors and runtime sizes in the PR.

## Governance-floor evidence and relaunch gate

The 99.5% floor has only about 0.15 percentage points left after the live USDRIF path's 0.35% LP-fee
stack, before price impact, pool/oracle drift, and stablecoin peg drift. USDT0's direct 0.30% pool is only
slightly looser. A caller minimum can tighten this floor but cannot make a sound trade pass when the floor
itself is too tight. R51 therefore surfaces the evidence rather than leaving the question between specs.

**Correction recorded during implementation (2026-08-31).** This spec listed *Sovryn DOC* as a shipped Dex
path. It is not one, and must never become one: **DOC buys rBTC only through MoC redemption.** DOC may appear
in a Uniswap path solely as an intermediate hop, never as a Dex handler's input token. The DOC Dex handler is
development-era legacy kept for tests, in the same position as Tropykus after R37 — no DOC Dex handler is ever
to be deployed. The shipped Dex set is therefore **LayerBank USDRIF and LayerBank USDT0**. PR 103 measured the
DOC path anyway and records the result as evidence for deleting it, not as a route awaiting calibration.
Separately, `DeployDexSwaps`' live branch can still construct that handler when `STABLECOIN_TYPE=DOC`, and its
comment at `script/DeployDexSwaps.s.sol:113` still names Sovryn (DOC) as part of the live dex map. Closing that
hole is deploy-script work outside R51's Solidity scope; it is tracked as the PR 50 follow-up in
[`IMPLEMENTATION_ORDER.md`](./IMPLEMENTATION_ORDER.md). Until it lands, the never-deploy rule above is
documentation only and is not enforced by the script.

**What gates PR 103.** The contracts PR must record one reproducible fork-derived measurement table, at a
named block, for every currently configured shipped handler/path (LayerBank USDRIF and LayerBank USDT0; see
the correction above for Sovryn DOC). Use the token's deployed minimum purchase and fee lower/upper bounds as the three reproducible input
points unless current bot data supplies better documented aggregate sizes; this choice must not require a new
product answer. The table records:

- exact encoded path and fee tiers;
- raw post-BitChill-fee input;
- pool quote, oracle-derived governance minimum, difference in basis points, block number/time, and the
  bot tolerance needed to turn the quote into `minRbtcOut`;
- whether the pool quote itself clears the current governance floor, and whether splitting/rebuilding a group
  or selecting another candidate path changes the result.

PR 103 must also open/update the swapper-bot and quote-engine issues with the relaunch acceptance criteria.
It may merge after recording that first table even when the result is “this route does not clear 99.5% at an
operational size.” It does not wait for the off-chain implementation, a multi-block observation window, or
the final enable/disable decision.

**What gates Dex relaunch.** Before enabling a route, the off-chain work extends that first table across
multiple recent blocks/observations and the supported batch-size envelope. Governance then approves the
highest static per-handler oracle backstop that clears that envelope with quantified quote-age/drift headroom,
never lower than the configured 95% safety floor. This is a maximum-loss boundary for a broken or compromised
bot, not the normal slippage control. The cutover record states the observed worst case, added headroom, chosen
percentage, maximum oracle-relative loss in basis points, and the Safe's approved loss budget. A route whose
required setting exceeds that budget stays disabled pending a better path, smaller supported envelope, or an
explicit product decision; routine liveness is not grounds to keep widening the floor.

The measured envelope includes every R52 path on which that handler's automatic failover claim relies. An
alternate that cannot clear the same chosen backstop at supported sizes does not qualify as automated failover;
switching paths must never trigger an automatic or routine Safe slippage change.

Install and re-lock that value while the route is disabled. First the handler owner calls
`setAmountOutMinimumPercent` with the approved backstop. After confirming `getAmountOutMinimumPercent`, a
**separate Safe execution** calls `setAmountOutMinimumSafetyCheck` with exactly the same value; do not combine
the calls in one MultiSend. Enable the route only after both getters match the cutover record. Equality is
valid, and restoring the safety check preserves R43's deliberate two-action speed bump: any later widening
must first lower the safety check and then lower the live percentage. The bot has permission to do neither.

Every Dex call still carries the fresh quote-derived `minRbtcOut`. The two predicates are independent and
the transaction obeys whichever is stricter. The bot does **not** suppress an otherwise viable transaction
merely because its quote-derived minimum is below the oracle floor: in that case the live oracle floor is the
stronger check. It avoids a transaction only when the pool quote itself cannot clear the estimated live floor,
then automatically requotes, splits the group, or activates another pre-approved R52 path. A single schedule's
purchase amount cannot be split across transactions; isolate an oversized outlier so it cannot block the rest
of the route. Human intervention is reserved for a structural condition that survives bounded retries and all
approved paths, not routine weekly price movement.

## Off-chain relaunch gate

The contracts PR may merge before the off-chain work, but BitChill must not relaunch Dex purchases until
the following acceptance criteria are implemented and tested. In the same turn as opening or updating the
contracts PR, search existing issues and update `swapper-bot#6` or the matching issue. Also open/update and
cross-link an `rsk-uniswap-pools` issue if that repository will supply the reusable quote engine.

- The swapper bot remains the only component with the signing key. Quote code is an imported module,
  package, or read-only service.
- Quotes cover every shipped Dex token/path: USDRIF and 6-decimal USDT0 (not DOC; see the correction above).
  Static route files are not assumed complete; the production allowlist/config is the source of candidate
  routes.
- All input/output arithmetic is integer-based. `minRbtcOut` is emitted as raw 18-decimal WRBTC wei, never
  a formatted decimal string.
- The quoted input is the batch's aggregate post-BitChill-fee stablecoin amount. A lending redemption can
  still return less than planned; the safe outcome is a minimum-output revert and a rebuilt/retried batch,
  not silently lowering the bound.
- A quote records the block used and has a configured maximum age. The tolerance is configurable per route
  and calibrated with Rootstock fork/live observations. Do not inherit `rsk-uniswap-pools`' current 0.5%
  default blindly. After a 0.30–0.35% fee stack its caller minimum may sit below the 99.5% oracle floor, so
  the floor—not R51—will be the stronger check; that is acceptable when logged, but the tolerance must still
  reflect the execution risk the bot intends to bound.
- Before broadcast, the bot logs the pool quote, its quote-derived minimum, and its estimate of the live
  governance floor. A lower quote-derived minimum is allowed—the handler's floor remains authoritative—but
  the quote itself must clear the estimated floor. Quoting failure triggers automatic retry/fallback, never a
  zero Dex minimum.
- Monitoring decodes both DcaManager purchase entry points, resolves each batch's handler/venue, and alerts on
  `minRbtcOut == 0` for a Dex batch. This is a high-signal broken-quoting or compromised-bot indicator, not an
  additional on-chain control (a malicious signer could send `1`). MoC batches deliberately use `0` and must
  not trigger this alert.
- The initial PR table and the later multi-observation calibration are attached to the bot/quote-engine issues.
  The relaunch record names the supported batch envelope, static per-handler floor and re-locked safety value,
  approved loss budget, approved path set, bounded retry/split/failover policy, and the condition that finally
  pages governance.
- MoC batches explicitly send `0` until a separate, tested redemption preview is implemented. Do not
  pretend the Uniswap pool calculator quotes MoC.
- Gas estimation, across-handler atomic fallback, per-handler retries, and paused/tail filtering continue
  to follow R42's consumer issue.

## Out of scope

- [ ] Dex path allowlisting or changing `setPurchasePath` authorization (R52).
- [ ] Changing `_getAmountOutMinimum`, the $1 peg, oracle, safety floor, or deploy defaults in PR 103. The
  relaunch runbook may use the existing owner setter once to install the approved per-handler backstop; the bot
  never changes it and routine failures never trigger automatic lowering.
- [ ] An on-chain Uniswap quoter, TWAP, private-relay dependency, or caller-supplied path.
- [ ] A mandatory nonzero minimum, deadline, or MoC quote formula.
- [ ] Changing across-handler atomicity, fee math, redemption/clamp policy, or purchase allocation rounding.
- [ ] Giving any additional process or repository the swapper private key.

## Files likely touched

- `src/interfaces/IDcaManager.sol`, `src/DcaManager.sol`
- `src/interfaces/IPurchaseRbtc.sol`, `src/PurchaseRbtc.sol`
- `test/utils/BatchBuyOne.sol`, the shared DcaManager harness, and every test/fuzz caller that constructs
  `IDcaManager.Batch` or calls the handler ABI
- focused min-out tests in `test/unit/` and the across-handler rollback suite

The tuple addition will cause a wide mechanical test diff. Name every changed path outside this list in
the PR body, as usual.

## Required tests

- `minRbtcOut == 0` reproduces current behavior on both MoC and Dex.
- Measured output equal to the minimum succeeds; one wei below reverts with both diagnostic values.
- A violated minimum rolls back schedule balances, timestamps, handler cash/share changes, fees,
  accumulated rBTC, and events.
- The comparison uses measured output after fees and actual retrieval, not gross/planned stablecoin or the
  router/MoC return value.
- 18-decimal DOC/USDRIF and 6-decimal USDT0-shaped inputs all supply an 18-decimal rBTC minimum.
- A caller minimum below the router oracle floor is inert on a successful swap; a stricter caller minimum
  can revert an output that satisfies the router floor. Test the two predicates independently.
- In `batchBuyRbtcAcrossHandlers`, a later batch's minimum failure rolls back an earlier handler batch.
- The one-handler `batchBuyRbtc(Batch)` retry enforces the same field.

Then run the `AGENTS.md` done-gate. Fork coverage must derive the Dex minimum from a live pool quote for the
exact post-fee input and compare it with the oracle floor; an oracle-derived value alone merely retests R43.
The caller minimum need not be stricter in that snapshot: record which predicate dominates and prove they are
independent. A no-liquidity or floor-too-tight result is valid PR evidence and moves to the relaunch calibration
rather than blocking the contracts PR.

## Success criteria

- [x] No caller value can loosen the governance floor.
- [x] The bound is checked against measured aggregate rBTC on every purchase venue.
- [x] PR 101's checks/effects/order and both entry-point shapes are preserved.
- [x] Every default-profile runtime remains below EIP-170 and the PR records the final margins.
- [x] The PR contains the first named-block fork table for every configured production path and operational
  size, including negative findings; it does not wait for multi-observation calibration or route enablement.
- [x] The off-chain issues are opened/updated with the relaunch acceptance criteria and linked in the contracts
  PR; their implementation and continuing calibration do not gate merge.
- [x] R9 indexing and R10 natspec rules are applied to the new error, field, and parameter.
- [x] No open contract product decisions.

## ABI / deploy / cutover impact

- **ABI:** both DcaManager purchase selectors change because `Batch` appends `minRbtcOut`.
  `IPurchaseRbtc.batchBuyRbtc` gains the same scalar parameter. New error:
  `PurchaseRbtc__BelowSwapperMinimum(uint256,uint256)`.
- **Deploy:** PR 103 makes no configuration/default change. While each Dex route remains disabled, relaunch
  performs two separately reviewed Safe executions per handler: install the explicit measured oracle backstop,
  verify it, then raise the safety check to the same value. There is no per-batch or weekly floor management.
- **Consumers:** update `swapper-bot#6` with the final tuple, raw-WRBTC units, quote/signing architecture,
  failure policy, and relaunch gate. Update `bitchill-monitoring#10` for the error/ABI and the Dex-only zero-
  minimum transaction-input alert; update `front-end#22` for the hardcoded ABI. Confirm that `data-api` does
  not encode `Batch`; no schedule model changes.
