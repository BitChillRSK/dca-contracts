# R68 — Enforce complete lending-share consumption

Status: **implemented** · Assigned: yes · Optional/further-review: no · Planning PR: [#123](https://github.com/BitChillRSK/dca-contracts/pull/123) · Implementation: [#124](https://github.com/BitChillRSK/dca-contracts/pull/124) · Order: after R67, before relaunch

## Objective

Make every successful lending redemption consume exactly the external receipt shares that
BitChill removes from its per-user virtual books. A smaller stablecoin payout may represent a
protocol fee or realized loss after the complete claim was consumed, but a protocol that pays only
part of a request and leaves the unpaid claim withdrawable must revert the whole BitChill operation.

## Background

`DcaManager._withdrawToken` deliberately reduces schedule principal by the requested amount rather
than by `ITokenHandler.withdrawToken`'s measured cash return. That is correct for Sovryn SIP-0094:
the iToken claim for the gross request is burned in full, the user receives the net amount, and the
difference is transferred to Sovryn's fee receiver. Re-crediting that difference would invent
principal the handler no longer owns.

The shared lending implementation currently proves only the cash side. `_redeemShares` and
`_batchRetrieveStablecoin` remove the intended shares from `s_shares`, then
`_measuredProtocolRedeem` measures the stablecoin balance delta and rejects only a zero receipt.
None of those paths measures how many receipt shares the lending protocol actually consumed. A
future adapter — or a changed protocol implementation — could therefore return positive cash for a
partial withdrawal while burning only the paid portion. BitChill would still remove the full share
debit and, on a principal withdrawal or purchase, the full schedule amount. The remaining external
shares would stay on the handler with no user attribution: an orphaned, still-withdrawable claim.

These are different outcomes and must not share one permissive rule:

| Outcome for a request backed by `S` shares | Stablecoin received | External shares consumed | Verdict |
| --- | ---: | ---: | --- |
| Full redemption, no fee | full (subject to rounding) | exactly `S` | succeed |
| Full redemption, exit fee / realized loss | less than requested | exactly `S` | succeed and debit the requested principal |
| Partial-liquidity fill | less than requested | less than `S`; the rest remains withdrawable | revert everything |
| Insufficient liquidity, atomic protocol | none; protocol reverts | none | propagate the revert; all BitChill state rolls back |

The currently integrated protocols are not known to silently partial-fill for utilization. Sovryn
checks available underlying before burning; LayerBank's Aave-v3-style withdrawal transfers the
requested underlying and reverts if the aToken lacks cash; Tropykus inherits Compound's
cash-before-redeem failure convention. High utilization therefore makes a request above free
liquidity revert, rather than paying the free-liquidity amount and leaving the rest pending. A user
may submit a smaller withdrawal later, but the protocol does not substitute that amount inside the
original call.

That behavior is also the synchronous composability convention. ERC-4626 requires `withdraw` to
send exactly the requested assets or revert, and exposes a limit through `maxWithdraw`. Protocols
that support delayed or partially claimable exits model them explicitly as requests/queues (for
example ERC-7540), not as a silent partial result from synchronous `withdraw`. Such a protocol
cannot be integrated through the current `ITokenHandler` / `LendingErc20Handler` lifecycle.

Primary references:

- [Sovryn `LoanTokenLogicSplit` burn implementation](https://github.com/DistributedCollective/Sovryn-smart-contracts/blob/development/contracts/connectors/loantoken/LoanTokenLogicSplit.sol)
- [SIP-0094 Perimeter withdrawal fee](https://github.com/DistributedCollective/SIPS/blob/main/SIP-0094.md)
- [Aave-v3 withdraw execution](https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/logic/SupplyLogic.sol)
- [Aave-v3 aToken burn and underlying transfer](https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/tokenization/AToken.sol)
- [Compound `redeemFresh` cash check](https://github.com/compound-finance/compound-protocol/blob/master/contracts/CToken.sol)
- [ERC-4626 synchronous withdrawal requirements](https://eips.ethereum.org/EIPS/eip-4626)
- [ERC-7540 asynchronous request lifecycle](https://eips.ethereum.org/EIPS/eip-7540)

## Open product decisions

**none.** The chosen rule is full external-share consumption or revert. Do not change schedule
principal to follow cash received: that would re-credit Sovryn's fee as withdrawable principal.

## Scope

- [x] Add a protocol invariant to `AGENTS.md`: after every successful lending redemption, the
      handler's external receipt-share balance must decrease by exactly the amount debited from
      BitChill's virtual share books. A smaller cash delta is allowed only when no part of that share
      claim remains. Future partial/queued integrations require a separate explicit lifecycle.
- [x] Change the lending redemption seam so every adapter measures its own receipt-share balance
      before and after the protocol call and reports that delta. Use `balanceOf(handler)` for Sovryn
      iTokens and Tropykus kTokens, and `scaledBalanceOf(handler)` for LayerBank aTokens. Do not trust
      a protocol return value as evidence of either cash received or shares consumed.
- [x] In the shared lending base, require the measured external share decrease to equal the intended
      virtual share debit. Revert with one diagnostic `ITokenLending` custom error carrying the
      intended decrease and enough before/after data to diagnose a zero, partial, excessive, or
      increasing balance. Avoid arithmetic panics when the post-call balance is not lower.
- [x] Apply the same postcondition to all three callers of the shared redeem path: principal
      withdrawals, interest withdrawals, and batch purchases. Any mismatch must roll back protocol
      movement, virtual-share updates, schedule/fee effects, transfers, and events.
- [x] Preserve balance-delta stablecoin accounting and `TokenLending__ZeroStablecoinReceived`.
      Positive cash plus an incomplete share burn now reverts; positive cash plus an exact share burn
      still succeeds even when cash is below the requested gross.
- [x] Make LayerBank consume the exact scaled-share amount passed by the shared base. Its Pool accepts
      underlying rather than shares and Aave converts with half-up RAY division, while BitChill sizes
      shares with a ceiling. Select the floor or one-base-unit-higher underlying amount that maps back
      to the intended scaled shares, then verify the actual `scaledBalanceOf` delta. Do not weaken the
      postcondition to `virtual shares <= protocol shares`, a one-share tolerance, or an
      adapter-specific unchecked assumption.
- [x] Rewrite `ITokenHandler.withdrawToken`, `IDcaManager.withdrawToken`, and their implementation
      comments around the enforceable rule: DcaManager may ignore measured cash only because a
      successful handler call guarantees no unpaid user-attributable claim remains withdrawable.
      Keep the measured `withdrawnAmount` return and the current requested-principal debit.
- [x] Extend the lending mocks to distinguish (a) exact share consumption with a cash haircut,
      (b) positive-cash partial share consumption, and (c) an atomic insufficient-liquidity revert.
      Keep LayerBank's existing payout-cap mode as case (a); it models a fee/loss, not a liquidity
      partial fill, because it currently burns the complete share amount before capping cash.
- [x] Record the successful-path gas delta for one principal withdrawal and 1-, 10-, and 200-row
      lending purchases, plus every lending leaf's deployed runtime size, against R68's base commit.

### Required implementation shape

The external receipt-share delta is a second measurement, independent of the stablecoin delta. The
shared base owns the exact-consumption verdict; each adapter owns only how its receipt balance is
read and how the protocol is called. A protocol's claimed burned amount is not sufficient.

For LayerBank, do not compare rebasing `aToken.balanceOf`: BitChill's book and the Pool burn are both
in scaled units. The implementation must retain R67's equality — total external scaled shares
consumed equals the sum of per-row virtual debits — rather than merely retaining the older solvency
inequality. If exact scaled consumption cannot be demonstrated against the live Pool because its
rounding differs from the verified Aave implementation, stop and report the observed before/after
values; do not ship a tolerance that can also admit a genuine partial fill.

## Out of scope

- [ ] Debiting schedule principal by `withdrawnAmount`, returning per-row cash or principal results
      to `DcaManager`, or re-crediting any redemption shortfall.
- [ ] A minimum payout ratio, fee ceiling, loss socialization, insurance, or special-casing SIP-0094's
      current 0.1% rate. Exact claim consumption and cash amount are intentionally separate facts.
- [ ] Supporting an async request/claim queue, withdrawal tickets, cooldowns, or partial-liquidity
      fills. Those require a new handler lifecycle and explicit pending-claim accounting.
- [ ] Reading protocol liquidity views as a redemption ceiling or preflight guarantee. Submit the
      intended atomic redemption and let the protocol or the postcondition revert.
- [ ] Removing the handler withdrawal return, changing `DcaManager.withdrawToken` arguments, changing
      event signatures, or changing R67's per-row share sizing and all-or-nothing batch behavior.
- [ ] Lending-share dust whose converted stablecoin amount is zero (the existing R15 deferral),
      Uniswap exact-input checks (R59), fee-on-transfer token support, or an owner rescue path.

## Files likely touched

- `AGENTS.md`
- `src/interfaces/ITokenHandler.sol`
- `src/interfaces/ITokenLending.sol`
- `src/interfaces/IDcaManager.sol`
- `src/DcaManager.sol` (comments only expected)
- `src/LendingErc20Handler.sol`
- `src/sovryn/SovrynErc20Handler.sol`
- `src/layerbank/LayerBankErc20Handler.sol`
- `src/tropykus-legacy/TropykusErc20Handler.sol`
- `test/mocks/MockLayerBank.sol`
- `test/mocks/MockIsusdToken.sol`
- `test/mocks/MockKdocToken.sol`
- `test/unit/LendingErc20HandlerRedeemTest.t.sol`
- `test/unit/NetRedemptionTest.t.sol`
- Dedicated Sovryn, LayerBank, and Tropykus handler tests only where adapter-specific measurement or
  rounding requires it
- Existing fork harness/tests only where needed for live receipt-share delta assertions

The implementer may follow direct imports, inheritance, mocks, failing tests, and compiler errors
from this list. Extra files must be named in the PR write-up.

## Required tests

Targeted shared and adapter tests first:

```text
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract LendingErc20HandlerRedeemTest -vvv
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract NetRedemptionTest -vvv
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract SovrynErc20HandlerTest -vvv
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC \
  forge test --match-contract LayerBankErc20HandlerTest -vvv
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --match-contract TropykusErc20HandlerTest -vvv
```

- Exact cash and exact receipt-share consumption succeeds. Assert the user's virtual debit equals
  the handler's external receipt-share balance decrease.
- Sovryn-style net cash with the complete iToken burn succeeds. Assert the user receives the net
  amount, the schedule loses the requested gross, and the remaining schedule principal is still
  fully backed and withdrawable.
- The existing LayerBank payout-cap case succeeds only when it burns the complete intended scaled
  shares. Its cash haircut must not be mistaken for a partial share redemption.
- A mock that pays a positive fraction and burns only the corresponding fraction reverts with the
  new share-consumption error. Assert full rollback of the schedule balance and timestamp (for a
  purchase), fee transfer, user and protocol share balances, handler/user stablecoin balances,
  accumulated rBTC, and all share-transition events.
- Exercise that mismatch through principal withdrawal, interest withdrawal, and a lending batch;
  do not prove only one caller while leaving another on a weaker helper.
- A mock liquidity-shortage revert before any burn or payment propagates and leaves all BitChill and
  protocol state unchanged. Do not implement a free-liquidity clamp.
- A protocol that burns more than requested or whose receipt balance increases also hits the named
  mismatch rather than an arithmetic panic.
- LayerBank tests cover awkward underlying amounts and non-RAY indices on both sides of Aave's
  half-up boundary. Each successful call must have exact equality, not a tolerance, between virtual
  scaled shares debited and actual scaled shares burned. Flip the one-unit adjustment or the
  share-delta check and show that the regression fails.
- Batch tests retain R67's equality for multiple users and repeated rows: the sum of per-row event
  share amounts, the virtual-book decrease, the requested protocol consumption, and the measured
  external receipt-share decrease are all equal.
- Zero cash after a positive exact share burn still reverts `TokenLending__ZeroStablecoinReceived`
  and rolls the burn back.

Then run the full local/deploy gates and every affected live adapter lane:

```text
make check
make check-deploy
make fork-sovryn
make fork-layerbank
make fork-tropykus
```

Add live fork assertions that a representative successful redemption decreases Sovryn iTokens,
LayerBank scaled aTokens, and legacy Tropykus kTokens by exactly the virtual debit. Do not attempt to
manufacture high utilization or a partial fill on a live market; deterministic mocks own the
failure cases. If `RSK_MAINNET_RPC_URL` is unset, stop before push as required by `AGENTS.md`.

## Success criteria

- [x] Every successful lending redemption consumes exactly the external receipt shares removed from
      BitChill's virtual books, across principal, interest, and batch purchase paths.
- [x] Positive cash cannot make a partial external share burn look successful.
- [x] A cash haircut remains valid when the complete claim was consumed; SIP-0094 net payout still
      debits requested principal and creates no phantom principal.
- [x] High-utilization/insufficient-cash behavior stays atomic: revert and rollback, never clamp to
      free liquidity.
- [x] LayerBank exactness is proven in scaled units across rounding boundaries and on a live fork.
- [x] The interface and `DcaManager` comments state the exact successful-call postcondition rather
      than the weaker “may not still hold the difference” rationale.
- [x] The new invariant tells future adapter authors to use a separate lifecycle for partial or
      asynchronous withdrawals.
- [x] R67's per-row exact-sum accounting and all existing balance-delta cash rules remain intact.
- [x] Focused tests, `make check`, `make check-deploy`, and all three required fork lanes pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Cash received and external shares consumed are measured and asserted independently.
- [ ] No third-party return value or liquidity view is trusted as either measurement.
- [ ] Exact external consumption is checked in the shared path used by withdrawal, interest, and
      purchase, with no adapter-specific fail-open bypass.
- [ ] LayerBank compares `scaledBalanceOf` and does not hide Aave rounding behind a tolerance.
- [x] The partial-burn regression pays positive cash and proves complete transaction rollback.
- [ ] The SIP-0094 regression still succeeds with net cash and a full share burn.
- [ ] Tests in the PR match **Required tests**, including the live adapter checks.
- [ ] Gas and deployed-size deltas are recorded against the named base commit.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: additive `ITokenLending` diagnostic custom error only. No function selector, argument, return,
  event signature, indexed field, or ERC-165 interface id changes. Existing events' share amounts
  become an enforced statement about the measured external decrease rather than an intended debit.
- Scripts: none expected. No constructor or configured address changes.
- Cutover: the implementation PR must search for and update/open issues on `bitchill-monitoring`
  (new error and strengthened event meaning), `swapper-bot` (a new whole-batch revert that should
  quarantine/fail over the venue rather than retry unchanged), and `front-end` (a principal exit can
  surface the new handler error). No `data-api` or `metrics-dashboard` change is expected.
