# Nethermind AuditAgent — provenance and dispositions

## Provenance

The human supplied [the original report](./audit-agent-report.md) and identified its producer as
Nethermind's AuditAgent. Its scan date is 2026-10-06 and its scan ID is
`ca256ac8-f203-4034-ab2a-1656bef69a13`.
It identifies branch `docs/r113-audit-readiness-docs` and commit `284b3500...bb3be0f8`.
The branch's full commit is `284b3500ed35b8ee8fc8802b7a3bb0f7bb3be0f8` (R113).

The original artifact is unchanged, including its severity labels and score.
Its SHA-256 is `cdfdc50d03787e7fc0fdf861ee50ac5b78e352c998c3a22bc6bacb4e59abc4e5`.
This automated scan is not a manual engagement by Nethermind's auditors.
BitChill's assessment below is separate from the scanner's claims.
Report annotations and suggested changes are evidence, not implementation instructions.

## Decisions — 2026-10-07

All six mechanisms are reproducible under their stated conditions. None is dismissed as a false positive.
The first three Medium labels do not describe an unconditional loss to ordinary users.
The human authorized accounting fixes after reviewing the initial documentation-only PR.
The final decisions below supersede that PR's initial acceptance of findings 1, 5, and 6.

| Finding | Original severity | Final disposition | Action |
|---------|-------------------|-------------------|--------|
| 1. Rounded withdrawals reduce principal backing | Medium | Fixed | Reserve shares for remaining principal before withdrawals; use the same reserve for interest quotes |
| 2. Stablecoin premium weakens the one-dollar floor | Medium | Accepted peg assumption | Retain the floor and quote-derived caller protection |
| 3. Nonpayable accounts cannot claim native rBTC | Medium | Accepted account limitation | State receiving requirements for users and the fee collector |
| 4. Registry affiliation does not authenticate the manager | Low | Operational mitigation; owner trust retained | Verify exact manager, token, and released code before acceptance or assignment |
| 5. LayerBank mint rounding leaves a purchase one share short | Low | Fixed | Fund purchases from available receipt shares and reduce the affected buyer's allocation weights |
| 6. Separate ceilings exceed a repeated buyer's shares | Low | Fixed | Convert each buyer's combined input once, independent of row order |

Accepted conditions remain possible in the contracts. Operational checks prevent assignment mistakes
when followed; the owner can still assign a wrongly bound handler. Fixes address the arithmetic
triggers, not external market illiquidity, realized losses, or incompatible protocol upgrades.

## 1. Withdrawals and the final purchase

The manager records nominal stablecoin principal. The handler records measured receipt shares.
Previously, an upward-rounded withdrawal could consume shares needed by remaining principal.
At `1.1 RAY`, withdrawing interest left `1,000 DOC - 1` base unit against `1,000 DOC` principal.
A partial principal withdrawal similarly left `100 DOC - 1` against `100 DOC` principal.
The final purchase reverted and rolled back the whole batch. Continuous yield could hide this gap;
additional interest was never a guarantee.

**Fix:** reserve `ceil(remainingPrincipal × scale / rate)` shares before sizing withdrawals.
The manager's new `getLockedPrincipal(user, token, handler)` reads remaining schedule liabilities
through the permanent registry after the existing schedule effects. It includes paused schedules.
The handler values only shares above that reserve. It still measures cash and proves exact external
share consumption. A rounding-limited payout can be slightly smaller than the nominal request.

Interest quotes and top-ups use the same reserved-share calculation. Their quote can be slightly
smaller than subtracting nominal principal from the value of all shares. This keeps displayed and
spendable interest consistent with the withdrawal rule.

Regressions now complete the previously failing purchases. Other tests cover paused schedules,
deletion, combined principal/interest withdrawal, and 1,000 fuzzed indices and withdrawal amounts.
If principal was backed before the operation, remaining shares still cover it afterward at that rate.
External losses can already leave principal unbacked; a reserve cannot manufacture missing shares.

## 2. An upward depeg

A fair pool can return more rBTC when the stablecoin trades above one USD.
The contract credits that actual measured output.
However, the BTC/USD-derived minimum still values each stablecoin at one USD.
It does not require the pool to pay the premium.

The reproduction uses the report's allowed 95% floor, not the 97% launch default.
For 100 stablecoins and BTC/USD of 100,000, the floor is `0.00095 rBTC`.
At a hypothetical 20% stablecoin premium, that output represents only 79.17% of the input's USD value.
A zero caller minimum permits this output.
A tighter quote-derived `minRbtcOut` can refuse it.
The mock test does not prove a profitable attack against any live pool.

**Decision:** accept the one-dollar assumption and retain the current floor.
The human accepts upward-depeg exposure.
Correct the earlier statement that every depeg stops purchases: the floor can stop downward-depeg swaps,
but it does not detect a premium.
The existing bot quote requirement remains in force.
No stablecoin/USD feed or additional peg check is introduced.

## 3. Native receiving requirements

A contract can approve stablecoin and create a schedule while rejecting native rBTC transfers.
Purchases still credit that account.
Withdrawal pays the credited signer, and an empty-calldata native transfer then fails.
The failed claim restores the credit atomically.
An immutable account that always rejects native rBTC cannot claim through the supplied paths.

**Decision:** accept this unsupported-account limitation, including for the fee collector.
The human states that the first Ivan Fitro audit found this limitation and that the relaunch deliberately retains it.
Users must use EOAs or accounts that can receive native rBTC with empty calldata.
A contract account must support a payable `receive()` or a compatible payable fallback.
Dex claims unwrap WRBTC before payment and have the same requirement.
Do not introduce an alternate recipient, owner rescue, or wrapped-token claim path.

## 4. Handler assignment and manager identity

`assignHandler` verifies that the handler's reported manager returns the same registry.
Another manager or an impostor can return that registry.
Only the registry owner can assign the handler.
The reproduction confirms that an unprivileged caller cannot do so.

If the owner assigns an official handler bound to an impostor, the canonical manager cannot use it.
If a victim then approves that handler, the impostor can pull those approved tokens through handler entry points.
The test demonstrates this conditional exposure with an official idle handler deployed through its script.
It does not demonstrate a bypass of the owner check or access to correctly bound handlers.

**Decision:** keep trusted governance and add exact checks to the
[cutover procedure](../../docs/relaunch/CUTOVER_RUNBOOK.md).
Operators must verify `handler.i_dcaManager() == deployedDcaManager`, `handler.i_stablecoin() == token`,
and the handler's verified code against the released artifact and constructor arguments.
They must also verify `dcaManager.i_operationsAdmin() == operationsAdmin`.
A matching registry getter alone is insufficient.

The initial deployment configures the registry under the deploying EOA before Safe ownership acceptance.
Later assignments require the Safe owner.
The initial deployment must pass the checks before acceptance or publication.
Later handlers must pass them before the Safe approves permanent assignment.
`FinalDeploymentTest` already asserts exact manager and token wiring for all seven launch handlers.
No canonical-manager storage or new registry ABI is added.

## 5. LayerBank mint rounding versus a future burn upgrade

At `1.01 RAY`, a current half-up mint gives `24,752,475,247,524,752,475` shares for 25 DOC.
The former full-principal purchase required one additional share and failed at the same index.
No withdrawal, malicious token, market loss, or proxy upgrade was necessary.

**Fix:** preserve the remaining principal reserve, then cap the buyer's combined debit to available
shares. If that cap reduces funding, value the debited shares and reduce only that buyer's row weights.
Differences of cumulative floors split the reduced funding exactly across that buyer's rows.
Their weights sum to the funded amount and never exceed the nominal row amounts.
The shared purchase pipeline calculates fees and output allocations from these adjusted weights.
The venue still spends only measured redeemed cash, and its input-consumption check remains exact.

Deposits and schedule debits remain nominal. Receipt shares are the actual lending claim.
An ordinary rounded deposit is accepted; the final purchase consumes the available claim instead of
failing for one missing share. There is no invented share, fixed dust tolerance, or use of another
buyer's shares. Full claims after a realized loss can also receive reduced funding. If no shares are
available above remaining principal, or no positive stablecoin can be funded, the whole batch reverts.
The swapper's minimum remains binding, so an unattainable nominal-input quote can still refuse the batch.

Tests cover a fresh 25-DOC purchase, three purchases at a flat index through the final tick, and
an enlarged mock shortfall with non-adjacent rows. The enlarged case proves that a healthy buyer
retains its funding weight. A failed output minimum restores all schedules, shares, and credits.
A shared-pipeline test confirms variable fees are recalculated from reduced weights.

A future LayerBank burn-rounding upgrade remains a separate integration risk.
The adapter still assumes today's half-up burn and a liquidity index of at least RAY.
A changed burn can cause `LendingHandler__ShareConsumptionMismatch` and require a new handler route.
The live probe and fork release gate check that assumption; these fixes do not relax exact consumption.

## 6. Repeated buyers and positive interest

`sum(ceil(rowAmount × scale / rate))` can exceed `ceil(sum(rowAmount) × scale / rate)`.
With `k` rows, the excess is at most `k - 1` shares. The previous per-row debits could therefore
reject a fully backed buyer, and one underlying base unit of extra interest did not always help.

**Fix:** group buyers in memory, including non-adjacent rows. Convert each combined amount once.
Debit each buyer once and redeem exactly the sum of those debits. No pro-rata share ceiling follows
the conversion. Purchase events retain their input row order, and calldata needs no new grouping rule.
`LendingHandler__UserSharesUpdated` now emits one transition per unique buyer per batch.

The grouping uses a half-full memory hash table with linear probing. Tests include colliding buckets.
It writes no persistent grouping state. The share book has one write per buyer; Rootstock prices each
nonzero-to-nonzero write at 5,000 gas. No net gas saving is claimed: grouping and principal reads add work.
The manager's principal read scans the user's token schedules, bounded by the configured schedule cap.
Operators must continue to simulate batches and choose a suitable batch size.

Regressions use the reserve-safe top-up quote introduced by finding 1's fix. At `1.7 RAY`, two
combined purchases need exactly the held shares while separate ceilings need one more.
A second case uses three rows at `1.5 RAY` and adds exactly one underlying base unit of interest.
Separate ceilings still exceed held shares; the aggregate conversion succeeds and keeps any excess claim.
The historical 300-DOC reproduction in the initial PR assumed the former, larger interest quote.

## Validation

The [audit regression file](../../test/ai-generated/audit/NethermindAuditFindings.t.sol) uses local
mocks and production contract paths. Local tests prove behavior, not live incident frequency.
Additional base tests cover fees, reduced-weight conservation, exact share burns, and rollback.
Direct-call manager fixtures now implement the remaining-principal read with zero liabilities.
The existing tail-revert tests now assert successful claim consumption.

The full default and deploy gates pass all eight unit lanes and all five invariant suites.
Each profile passes 24 invariant tests; no suite reports a failure. Both lending fork gates pass
487 tests, with zero failures and 36 existing lane skips. Slither and Aderyn were rerun; their
unsuppressed baseline and new accounting observations are documented in
[R114](../../docs/relaunch/R114-nethermind-audit-followups.md). PR 180 records latest CI and artifact checks.

Consumer follow-ups:

- [front-end#11](https://github.com/BitChillRSK/front-end/issues/11#issuecomment-6045133192): principal getter and reserve-safe interest quotes.
- [bitchill-monitoring#10](https://github.com/BitChillRSK/bitchill-monitoring/issues/10#issuecomment-6045133656): per-buyer share events and adjusted funding semantics.
- [swapper-bot#15](https://github.com/BitChillRSK/swapper-bot/issues/15#issuecomment-6045134182): quote and simulate actual gross funding.
