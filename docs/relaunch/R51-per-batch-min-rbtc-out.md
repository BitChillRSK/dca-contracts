# R51 — Per-batch minimum rBTC output

Status: **not started** · Assigned: no · Optional/further-review: no

PR 50 of the relaunch stack; planned GitHub implementation PR **#103**. Stack on R42's integration
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

**No open product decisions.** Implement these choices:

1. Append `uint256 minRbtcOut` as the final field of the existing `IDcaManager.Batch`. It is the minimum
   aggregate output for that one handler batch, in **WRBTC/native rBTC wei (18 decimals)**. Stablecoin
   decimals affect the quote input, never the units of this field.
2. Permit `minRbtcOut == 0`. It exactly preserves the oracle-floor-only behavior and lets MoC ship before
   an off-chain MoC redemption preview exists. The production bot must nevertheless send a meaningful
   nonzero value for every Dex batch; that is an off-chain relaunch gate below.
3. Keep `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT = 99.5%` and the 95% safety floor. The caller bound is optional
   on-chain and does not justify weakening the last defense against a buggy or compromised swapper. R51 also
   owns the measurement-backed liveness decision below: a route that cannot clear the governance floor plus
   the bot's quote tolerance stays disabled at relaunch. Do not silently lower the floor to make a test pass.
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
against PR 101 and produces `Stack too deep` under `via_ir = false`. Extract the per-buyer
allocation/credit loop into a private `_creditBuyers` helper as part of R51, without changing its arithmetic,
ordering, rounding, accumulated-balance writes, or event sequence. The same code happens to compile with
`via_ir = true`, but that profile is not selected by any deployment command or required test lane and is not
a reason to skip the extraction. Re-measure every handler and DcaManager; do not copy the obsolete combined
R51/R52 prototype figures.

## Scope

- [ ] `IDcaManager.Batch` appends `uint256 minRbtcOut`, with natspec that fixes its aggregate semantics and
  WRBTC-wei units. `batchBuyRbtc(Batch)` and `batchBuyRbtcAcrossHandlers(Batch[])` keep their PR 101 shapes,
  but both selectors change because the tuple changes.
- [ ] `DcaManager._batchBuyRbtc` forwards `batch.minRbtcOut` to the resolved handler. Preserve every PR 101
  check, effect, ordering decision, and one-handler retry path.
- [ ] `IPurchaseRbtc.batchBuyRbtc` gains `uint256 minRbtcOut`.
- [ ] `PurchaseRbtc.batchBuyRbtc` reverts
  `PurchaseRbtc__BelowSwapperMinimum(uint256 rbtcReceived, uint256 minRbtcOut)` when measured aggregate
  output is below the caller minimum, after the existing zero check and before credits.
- [ ] Extract the required `_creditBuyers` helper. Planned net amounts remain allocation weights; the
  denominator, truncation, accumulated-balance writes, and per-row events are unchanged.
- [ ] Record final method selectors and runtime sizes in the PR.

## Governance-floor liveness gate

The 99.5% floor has only about 0.15 percentage points left after the live USDRIF path's 0.35% LP-fee
stack, before price impact, pool/oracle drift, and stablecoin peg drift. USDT0's direct 0.30% pool is only
slightly looser. A caller minimum can tighten this floor but cannot make a sound trade pass when the floor
itself is too tight. R51 therefore owns this question rather than leaving it between contract specs.

Before declaring any Dex route ready for relaunch, the R51 PR and linked off-chain issues must record a
measurement table for every shipped handler/path (Sovryn DOC, LayerBank USDRIF, and LayerBank USDT0):

- exact encoded path and fee tiers;
- raw post-BitChill-fee input at the smallest, normal, and largest proposed operational batch sizes;
- pool quote, oracle-derived governance minimum, difference in basis points, block number/time, and the
  bot tolerance needed to turn the quote into `minRbtcOut`;
- more than one recent block or observation point, so one favorable snapshot is not treated as calibration;
- whether splitting/rebuilding a batch or switching to another governance-approved R52 path restores enough
  headroom for the quote-derived minimum to remain strictly above the governance floor.

The settled failure policy is conservative: retain the 99.5% / 95% source defaults, and do not broadcast a
Dex batch whose quote-derived minimum cannot be stricter than the governance floor. Retry with a fresh quote,
split/rebuild the batch, or use an approved failover path. If the smallest operational batch still cannot
clear both bounds, that route remains disabled at relaunch and the finding is escalated as a separate,
measurement-backed governance proposal; neither the R51 implementer nor the bot lowers the handler setting
automatically. This makes availability loss explicit without weakening the compromised-swapper boundary.

## Off-chain relaunch gate

The contracts PR may merge before the off-chain work, but BitChill must not relaunch Dex purchases until
the following acceptance criteria are implemented and tested. In the same turn as opening or updating the
contracts PR, search existing issues and update `swapper-bot#6` or the matching issue. Also open/update and
cross-link an `rsk-uniswap-pools` issue if that repository will supply the reusable quote engine.

- The swapper bot remains the only component with the signing key. Quote code is an imported module,
  package, or read-only service.
- Quotes cover every shipped Dex token/path: DOC, USDRIF, and 6-decimal USDT0. Static route files are not
  assumed complete; the production allowlist/config is the source of candidate routes.
- All input/output arithmetic is integer-based. `minRbtcOut` is emitted as raw 18-decimal WRBTC wei, never
  a formatted decimal string.
- The quoted input is the batch's aggregate post-BitChill-fee stablecoin amount. A lending redemption can
  still return less than planned; the safe outcome is a minimum-output revert and a rebuilt/retried batch,
  not silently lowering the bound.
- A quote records the block used and has a configured maximum age. The tolerance is configurable per route
  and calibrated with Rootstock fork/live observations. Do not inherit `rsk-uniswap-pools`' current 0.5%
  default blindly: after a 0.30–0.35% fee stack it is normally below the 99.5% oracle floor and adds no
  protection.
- Before broadcast, the bot proves/logs that its quote-derived minimum is stricter than its estimate of the
  governance floor. If it is not, or quoting fails, it does not broadcast that Dex batch and alerts/retries.
- The governance-floor measurement table above is attached to the bot/quote-engine issue. Every enabled route
  passes at its documented operational sizes; a failing route is explicitly disabled rather than omitted.
- MoC batches explicitly send `0` until a separate, tested redemption preview is implemented. Do not
  pretend the Uniswap pool calculator quotes MoC.
- Gas estimation, across-handler atomic fallback, per-handler retries, and paused/tail filtering continue
  to follow R42's consumer issue.

## Out of scope

- [ ] Dex path allowlisting or changing `setPurchasePath` authorization (R52).
- [ ] Changing `_getAmountOutMinimum`, the $1 peg, oracle, safety floor, or deploy defaults. A measured
  proposal to lower a live handler setting is a separate governance decision, not an automatic R51 fix.
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
exact post-fee input and show it is stricter than the oracle floor; an oracle-derived value alone merely
retests R43. A no-liquidity or floor-too-tight result must be recorded as a disabled relaunch route, not
silently skipped as though the liveness decision passed.

## Success criteria

- [ ] No caller value can loosen the governance floor.
- [ ] The bound is checked against measured aggregate rBTC on every purchase venue.
- [ ] PR 101's checks/effects/order and both entry-point shapes are preserved.
- [ ] Every default-profile runtime remains below EIP-170 and the PR records the final margins.
- [ ] Every enabled production Dex route has the required multi-observation floor/headroom table; any route
  that cannot support a meaningful stricter caller bound is explicitly disabled for relaunch.
- [ ] The off-chain issues contain the acceptance criteria above and are linked in the contracts PR.
- [ ] R9 indexing and R10 natspec rules are applied to the new error, field, and parameter.
- [ ] No open contract product decisions.

## ABI / deploy / cutover impact

- **ABI:** both DcaManager purchase selectors change because `Batch` appends `minRbtcOut`.
  `IPurchaseRbtc.batchBuyRbtc` gains the same scalar parameter. New error:
  `PurchaseRbtc__BelowSwapperMinimum(uint256,uint256)`.
- **Deploy:** no automatic configuration/default change. The cutover record names enabled and disabled Dex
  routes from the floor-liveness measurement; lowering a live handler setting requires separate approval.
- **Consumers:** update `swapper-bot#6` with the final tuple, raw-WRBTC units, quote/signing architecture,
  failure policy, and relaunch gate. Update `bitchill-monitoring#10` for the error/ABI and `front-end#22`
  for the hardcoded ABI. Confirm that `data-api` does not encode `Batch`; no schedule model changes.
