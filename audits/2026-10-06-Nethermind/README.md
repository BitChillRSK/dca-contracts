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

All six mechanisms are reproducible under their stated conditions.
None is dismissed as a false positive.
The scanner's first three Medium labels do not describe an unconditional loss to ordinary users.
BitChill treats the rounding cases as Low availability risks and the remaining cases as explicit
deployment assumptions or unsupported use.

| Finding | Original severity | BitChill disposition | Action |
|---------|-------------------|----------------------|--------|
| 1. Rounded withdrawals leave nominal principal short of share backing | Medium | Valid; accepted Low availability risk | Retain strict share accounting; add interest and principal withdrawal reproductions and exit checks |
| 2. Stablecoin premium weakens the one-dollar floor | Medium | Valid conditional exposure; accepted peg assumption | Correct depeg NatSpec and document quote-derived caller protection |
| 3. Nonpayable contract accounts cannot claim native rBTC | Medium | Valid for unsupported accounts; accepted limitation | State receiving requirements for users and the fee collector |
| 4. Registry affiliation does not authenticate the canonical manager | Low | Valid trusted-governance risk; mitigated operationally | Check the exact immutable manager, token, and released code before acceptance or assignment |
| 5. Current LayerBank mint rounding can leave a fresh purchase one share short | Low | Valid; accepted Low availability risk | Add a fresh-deposit reproduction; distinguish it from burn-rounding upgrades |
| 6. Separate ceilings for repeated buyers can exceed their aggregate shares | Low | Valid; accepted Low availability risk | Add repeated-buyer reproductions, including positive one-wei interest |

“Accepted” means the condition remains possible in the contracts.
“Mitigated operationally” means the procedure prevents a governance mistake when operators follow it.
The contracts still permit finding 4 after an incorrect owner assignment.
These decisions preserve the current product rules; they do not establish that every risk is unlikely.

## 1. Withdrawals and the final purchase

The manager records nominal stablecoin principal.
The lending handler records measured receipt shares and rounds share debits upward.
A withdrawal can consume a fraction of a share more than its nominal stablecoin debit.
That can leave a final purchase one share short without a market loss.
Repeated withdrawals or purchases can accumulate the discrepancy.
The discrepancy is bounded by the applicable rounding events, not universally by one underlying wei.

Tests reproduce both withdrawal triggers through the real manager and deployment helpers.
At index `1.1 RAY`, an interest withdrawal leaves `1,000 DOC - 1` base unit behind
`1,000 DOC` of recorded principal.
A principal withdrawal leaves `100 DOC - 1` base unit behind `100 DOC` of recorded principal.
The final purchase reverts with `LendingHandler__InsufficientShares`.
Activating a protected purchase window afterwards does not repair the existing gap.

The failed purchase rolls back schedule effects and share debits.
It can delay every other row in that batch, including other handlers in an atomic across-handlers call.
It does not authorize a user to withdraw another user's shares.
Principal exit clamps to available backing and remains possible in these tests.
The exact cash payout depends on the adapter's measured redemption, fees, and rounding.

**Decision:** retain the no-clamp purchase policy from
[R43](../../docs/relaunch/R43-dex-path-review.md) and
[R110](../../docs/relaunch/R110-internal-audit-followups.md).
Existing bot simulation must identify failing row sets before submission.
Omitting an affected row allows other buyers to proceed.
Additional backing, sufficient yield, a smaller purchase, or principal exit can resolve the affected position.
An unchanged retry is not a repair when the market does not accrue enough interest.

A reserve-based alternative must preserve enough shares for the remaining aggregate principal.
That requires coordinated withdrawal accounting; changing every ceiling to a floor is not a safe substitute.
No such redesign is assigned for this relaunch.
The human reports no production incidents, but this review does not independently verify that history.
Continuous yield can explain the absence of observed failures; it is not a contract guarantee.
The current batch-only purchase path also differs from the earlier single-purchase path removed by
[R39](../../docs/relaunch/R39-remove-single-buy.md).

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

At index `1.01 RAY`, the current half-up mint credits `24,752,475,247,524,752,475` shares for 25 DOC.
Purchasing that full principal requires `24,752,475,247,524,752,476` shares under the handler's ceiling.
The fresh schedule is therefore one share short at the same index.
No withdrawal, malicious token, market loss, or proxy upgrade is necessary.
The test also confirms principal exit after the failed purchase.

**Decision:** accept this rounding-tail availability risk under the same policy as finding 1.
Enough later yield can remove the gap, but zero or insufficient yield cannot guarantee a repair.

A future LayerBank burn-rounding upgrade is a separate risk.
The adapter sizes an underlying withdrawal for today's half-up burn and requires exact measured share consumption.
A changed burn rule can cause `LendingHandler__ShareConsumptionMismatch` and require a new handler route.
The existing live probe and fork release gate cover that assumption.
They do not eliminate the current mint-versus-ceiling mismatch described here.

## 6. Repeated buyers and positive interest

For each buyer, `sum(ceil(rowAmount × scale / rate))` can exceed
`ceil(sum(rowAmount) × scale / rate)`.
With `k` positive rows, the excess is at most `k - 1` shares relative to one aggregate conversion.
The handler debits each row separately and reverts if a later row exceeds the remaining shares.
A fully backed aggregate can therefore fail.

The first reproduction compounds 100 DOC of interest into two schedules.
At `1.5 RAY`, their purchases total 300 DOC against 200 scaled shares.
Their separate ceilings require `200e18 + 1` shares.
The failed batch preserves both schedules and the user's shares.

The second reproduction uses three 100-DOC rows after compounding.
It then increases the index from `1.5e27` by `5,000,000`, which adds exactly one underlying base unit of value.
The three ceilings still require `200e18 + 1` shares against `200e18` held shares.
Thus, “at least one wei of new interest” is not a sufficient guarantee.
The test does not estimate this event's frequency on a live market.

**Decision:** accept the Low availability risk and preserve strict row debits for this relaunch.
Existing simulation must cover the complete row set, including repeated buyers.
Sufficient new backing or smaller requested purchases can repair it.
Splitting the same requests into unchanged batches is not a guaranteed repair at a fixed rate.
Per-buyer aggregate conversion would address this trigger, but requires a purchase-accounting change and rounding allocation between rows.
[R79](../../docs/relaunch/R79-coalesce-repeated-buyer-writes.md) considered write coalescing;
that optimization is not itself a solution to the mathematical conversion issue.

## Reproduction and validation

The dedicated [test file](../../test/ai-generated/audit/NethermindAuditFindings.t.sol) uses local mocks
and production contract paths.
It does not change shared mocks or deployment helpers.

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC \
  forge test --match-path test/ai-generated/audit/NethermindAuditFindings.t.sol --match-test test_NM
FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC \
  forge test --match-path test/ai-generated/audit/NethermindAuditFindings.t.sol --match-test test_NM
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/deployment/FinalDeploymentTest.t.sol --match-contract FinalDeploymentTest
FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/deployment/FinalDeploymentTest.t.sol --match-contract FinalDeploymentTest
```

Validation results are recorded in [R114](../../docs/relaunch/R114-nethermind-audit-followups.md).
All eight new reproductions and six existing deployment tests passed under both profiles.
For each profile, all 42 first-party `src/` artifacts have identical ABIs and metadata-stripped runtime and creation code.
Ten artifacts contain creation code; their runtime metadata changes, so the comparison observes the NatSpec edits.
No live fork was run for this document, NatSpec, and isolated-test change.
The deployment release gates remain mandatory on the frozen release revision.
