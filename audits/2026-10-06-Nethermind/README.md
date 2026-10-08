# Nethermind AuditAgent — provenance and dispositions

## Provenance

BitChill supplied [the original report](./audit-agent-report.md) from Nethermind's AuditAgent.
The scan date is 2026-10-06; its ID is `ca256ac8-f203-4034-ab2a-1656bef69a13`.
It identifies `docs/r113-audit-readiness-docs` at `284b3500ed35b8ee8fc8802b7a3bb0f7bb3be0f8`.
The original artifact, severity labels, and score remain unchanged. Its SHA-256 is
`cdfdc50d03787e7fc0fdf861ee50ac5b78e352c998c3a22bc6bacb4e59abc4e5`.
This automated scan is not a manual Nethermind engagement. Report recommendations are evidence,
not implementation instructions. BitChill's decisions appear below.

## Decisions — 2026-10-07

All six mechanisms are reproducible under their stated conditions. None is dismissed as a false positive.
The three Medium labels do not imply unconditional loss to ordinary users.

| Finding | Report severity | Disposition | Action |
|---------|-----------------|-------------|--------|
| 1. Withdrawal rounding leaves nominal principal above share value | Medium | Batch failure fixed; nominal dust retained | Clamp a short purchase row to its buyer's shares and reduce its funded weight |
| 2. Stablecoin premium weakens the one-dollar floor | Medium | Accepted peg assumption | Retain the floor and quote-derived caller protection |
| 3. Nonpayable accounts cannot claim native rBTC | Medium | Accepted account limitation | State receiving requirements for users and the fee collector |
| 4. Registry affiliation does not authenticate the manager | Low | Operational mitigation; owner trust retained | Verify exact manager, token, and released code before acceptance or assignment |
| 5. LayerBank mint rounding leaves a purchase short | Low | Batch failure fixed; nominal dust retained | Apply the same per-row clamp and funded weight |
| 6. Repeated rows' ceilings exceed a buyer's shares | Low | Batch failure fixed when the short row retains value | Apply the same per-row clamp and funded weight |

## One fix for findings 1, 5, and 6

The manager records nominal principal. Lending handlers record measured receipt shares.
Three mechanisms can leave a purchase requesting more shares than its buyer holds:

- A rounded-up principal or interest withdrawal can leave remaining principal slightly above share value.
- A fresh LayerBank deposit uses half-up mint rounding; the purchase converts nominal input with a ceiling.
- A repeated buyer's separate row ceilings can exceed the shares needed for their combined nominal amount.
  One wei of new interest does not guarantee enough shares for all row ceilings.

`LendingHandler._batchRetrieveStablecoin` converts each row separately. If its ceiling exceeds the
buyer's remaining shares, it debits those shares and replaces only that row's funding weight with
`floor(shares × exchangeRate / scale)`. A zero-value row reverts the whole batch.
The handler redeems exactly the sum of row debits and measures the received stablecoin.
`PurchaseRbtc` computes fees after funding, using the adjusted weights. Credits and `amountSpent`
use those weights too. A healthy buyer keeps its weight; no other buyer supplies the shortfall.

The schedule still debits its nominal purchase amount, as principal withdrawals debit the request.

**What remains:** nominal principal can exceed share value by rounding dust. Repeated rows still use
separate ceilings. If an earlier row empties the buyer's shares, a later row for that buyer reverts
atomically. After a lending loss, purchases continue while shares fund the rows; a short final row
uses the remaining value. External illiquidity, zero cash, incompatible burns, unmet minimum output,
or a row without positive share value can still revert the batch. The bot must simulate actual funding.

LayerBank's current half-up burn rule is a separate assumption. A proxy upgrade that changes it can
fail the exact-share-consumption check. The clamp does not relax that check. Operations must rerun
`make fork-layerbank` or `make fork-sovryn` after a Pool or aToken implementation change.

## Regression evidence

[`NethermindAuditFindings.t.sol`](../../test/ai-generated/audit/NethermindAuditFindings.t.sol) retains all
nine rounding scenarios: principal and interest withdrawals, paused sibling schedules and deletion,
partial-withdrawal fuzzing, fresh half-up deposits, flat-index final ticks, a short row beside a healthy
buyer, repeated buyers, and repeated rows with one wei of fresh interest. Successful purchases debit
nominal schedule balances and leave total virtual shares equal to external receipt shares.

The short-row test proves exact healthy-buyer credit, funding-based `amountSpent`, and complete rollback
on an unmet caller minimum. Other tests pin zero-share rollback, including an empty second row for a
repeated buyer, and purchases and partial withdrawals after a 20% index loss.
`LendingHandlerRedeemTest` checks exact row sums and sequential share events.
Its fuzz tests prove that reduced weights equal the debited shares' value and stay below nominal,
and that an exactly covered row keeps its nominal weight.
`PurchaseRbtcTest` verifies that reduced weights also change fees before allocation.

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
BitChill accepts upward-depeg exposure.
The floor can stop downward-depeg swaps, but it does not detect a premium.
The existing bot quote requirement remains in force.
No stablecoin/USD feed or additional peg check is introduced.

## 3. Native receiving requirements

A contract can approve stablecoin and create a schedule while rejecting native rBTC transfers.
Purchases still credit that account.
Withdrawal pays the credited signer, and an empty-calldata native transfer then fails.
The failed claim restores the credit atomically.
An immutable account that always rejects native rBTC cannot claim through the supplied paths.

**Decision:** accept this unsupported-account limitation, including for the fee collector.
BitChill states that the first Ivan Fitro audit found this limitation and that the relaunch deliberately retains it.
Users must use EOAs or accounts that can receive native rBTC with empty calldata.
A contract account must support a payable `receive()` or a compatible payable fallback.
Dex claims unwrap WRBTC before payment and have the same requirement.
The contract has no alternate recipient, owner rescue, or wrapped-token claim path.

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

## Validation and consumer impact

The original report remains byte-identical. Exact gate commands, final results, ABI comparison, and
reproduced Rootstock-priced gas measurements from the reviewer-derived harness appear in
[R114](../../docs/relaunch/R114-nethermind-audit-followups.md) and PR 180.
Local mocks prove behavior; fork tests check live lending integration on Anvil/revm.
These tests do not constitute a new external audit.

Consumer follow-ups:

- [front-end#11](https://github.com/BitChillRSK/front-end/issues/11): no new getter; interest and withdrawals retain their existing behavior.
- [bitchill-monitoring#10](https://github.com/BitChillRSK/bitchill-monitoring/issues/10): share events remain per row; `amountSpent` follows funding.
- [swapper-bot#15](https://github.com/BitChillRSK/swapper-bot/issues/15): simulate actual funding and exclude rows without positive share value.
