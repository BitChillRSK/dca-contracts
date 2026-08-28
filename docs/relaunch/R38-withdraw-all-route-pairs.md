# R38 — Zip withdraw-all route pairs

Status: **not started** · Assigned: no · Optional/further-review: no

PR 45 of the relaunch stack. Stack on R37 (PR 44). **Must land before R9 (ABI freeze).** R18/R19/R50 and R39–R48 already settled the other DcaManager/handler ABI changes by this point.

## Objective

Make `withdrawAllAccumulatedInterest` and `withdrawAllAccumulatedRbtc` take explicit `(token, routeIndex)` pairs instead of two arrays expanded into a cartesian product, so a caller can express the exact set of routes it holds a balance on and stops calling handlers where it has no position. While the signature is open, align their empty-array policy with `batchBuyRbtc`.

## Background

Both functions loop `tokens × routeIndexes` and resolve a handler per combination
(`DcaManager.withdrawAllAccumulatedRbtc`, `withdrawAllAccumulatedInterest`). The caller therefore cannot
describe a set of pairs that is not a full grid. Any user whose positive balances span **two different
tokens and two different route indexes** forces combinations they do not hold:

| positive routes | call must be | product also hits |
|---|---|---|
| USDRIF×LayerBank, DOC×Sovryn | `[USDRIF, DOC] × [1, 2]` | DOC×LayerBank and USDRIF×Sovryn, whether registered or skipped |

R36 adds USDT0 as a second LayerBank dex stable. If decision 2 keeps a DOC/Sovryn arm on that same dex
map, the mixed grid is immediately shipped; if not, the add-only registry can still acquire partial
multi-token/multi-route coverage later. Neither case makes the cartesian form capable of expressing pairs.

Same-token/multi-route (`[DOC] × [1, 2]`) and multi-token/same-route (`[DOC, USDRIF] × [1]`) expand cleanly.
Only the mixed case produces no-ops.

**This is API precision, not a live defect.** One no-op combination after R37 costs a `getTokenHandler`
staticcall, an `isLendingRoute` staticcall, a full `_lockedPrincipal` pass over every schedule the user
holds for that token (evaluated *before* the handler call, so it runs regardless), a view exchange-rate
read, and then the `if (totalStablecoinInLending <= stablecoinLockedInDcaSchedules) return;` early exit in
`LendingErc20Handler.withdrawInterest` — no transfer, no event, no state change. The `_lockedPrincipal`
loop means the waste scales with the user's schedule count rather than being constant. `TropykusErc20Handler` is
the only handler that overrides `_exchangeRate()` with the state-changing `exchangeRateCurrent()`; every
other handler inherits the `_viewExchangeRate()` default from `LendingErc20Handler`. The market-wide
Compound `AccrueInterest` that BitChillRSK/front-end#13 observed on live kDOC is therefore a
Tropykus-specific symptom that R37 removes on its own.

What does **not** go away is the shape: a cartesian API cannot express a set of pairs, and after R9 the
signature is frozen for the life of the deployment. The frontend already worked around the half it could
(BitChillRSK/front-end#14 derives unique tokens and unique indexes from positive routes, which is exact for
single-route users and still over-broad for mixed ones). That workaround exists only because the contract
cannot be told the truth.

`batchBuyRbtc` is the same contract's answer to the same problem and it gets the shape right: a scalar
`token`, a scalar `routeIndex`, parallel arrays with an explicit length check, and a per-item
`DcaManager__RouteIndexMismatch`. The two withdraw-alls are the only entry points in `src/` that make a
caller over-specify, and the only nested loops. This PR makes them consistent with the pattern the
codebase already chose everywhere else.

### Reachability follows the final R36/R37 map

The mixed case needs **one `OperationsAdmin` map serving ≥2 tokens across ≥2 lending routes with partial
coverage**. `DeployMocSwaps` and `DeployDexSwaps` create separate admins/managers, so a MoC route and a Dex
route do not mix merely because both exist. R36 now lands before this PR and decides whether the dex map
itself keeps DOC/Sovryn alongside USDRIF/USDT0 on LayerBank; R37 then removes the live Tropykus arm. This
PR therefore tests the topology that actually ships instead of asking a future deployment gate early.

Even if that final map has only LayerBank-backed USDRIF/USDT0, do not treat simpler initial reachability as
a reason to skip the API correction. Route maps are add-only and schedules store `routeIndex` forever, so
a two-token/two-route partial map added later reintroduces the no-ops with no way to express the desired
pairs short of another redeploy.

## Open product decisions

**none** — decided 2026-08-27: replace the cartesian semantics (no parallel legacy selector) and keep the `withdrawAllAccumulated*` names. R34's no-dual-window cutover makes the same-selector semantic change acceptable; the PR must call it out explicitly.

## Scope

- [ ] `DcaManager.withdrawAllAccumulatedInterest`: single loop over zipped `(tokens[i], routeIndexes[i])`.
- [ ] `DcaManager.withdrawAllAccumulatedRbtc`: same.
- [ ] Length check on both, reverting with a new `DcaManager__WithdrawalArraysLengthMismatch()`, named to
      match the existing `DcaManager__BatchPurchaseArraysLengthMismatch()`.
- [ ] Keep every existing skip unchanged: `address(0)` handler, `!_tokenYieldsInterest(routeIndex)` on the
      interest path, and `getAccumulatedRbtcBalance == 0` on the rBTC path. A caller naming an unregistered
      or idle pair must still be skipped, not reverted.
- [ ] `IDcaManager` signatures and natspec, stating that arguments are positional pairs.
- [ ] Revert on empty arrays with a new `DcaManager__EmptyWithdrawalArrays()`, matching the existing
      `DcaManager__EmptyBatchPurchaseArrays()` on `batchBuyRbtc`. Both withdraw-alls currently succeed
      silently on empty input, so a caller whose route filter returned nothing gets a green transaction
      that did nothing. The frontend already guards `tokens.length === 0` before sending, so nothing
      legitimate is broken by making it explicit.
- [ ] Confirm `_tokenYieldsInterest` is no longer called per combination. It is an external staticcall to
      `OperationsAdmin.isLendingRoute` that depends only on the route index, so the current nested form
      makes `tokens.length × routeIndexes.length` calls where one per pair suffices. This falls out of the
      zip rather than needing its own change — assert it rather than implement it.
- [ ] Rename the misspelled `scheudulePurchaseAmount` local in `batchBuyRbtc` (`DcaManager.sol`, two
      occurrences) to `schedulePurchaseAmount`. Local variable only — no selector, event, error, or
      behavior change. **This spec explicitly authorizes it as an exception to the "No drive-by refactors"
      rule in `AGENTS.md`**, because it sits in a function this PR does not otherwise touch: R10's natspec
      pass does not reach local names, R32 is closed, and nothing else is scheduled to open this file
      before the freeze. Name it in **Files beyond the spec** in the PR body.
- [ ] Update tests, fuzz wrappers, and checked-in consumers to the paired form.

## Out of scope

- [ ] Handler-address uniqueness is already enforced by R47. Do not reopen its registry policy here.
- [ ] Frontend changes. `BitChillRSK/front-end` deletes its `uniqueTokensAndProtocolIndexes` util and passes
      routes straight through, but that is a separate repo and a separate cutover.
- [ ] R36 dex-map work, R37 Tropykus removal, and any deploy-script change.
- [ ] Combining principal and interest in one call.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `test/unit/StablecoinLendingTest.t.sol`
- `test/unit/RbtcWithdrawalTest.t.sol`
- `test/ai-generated/fuzz/Handler.t.sol`

`NetRedemptionTest.t.sol`, `RbtcPurchaseTest.t.sol`, `test/ai-generated/unit/DcaManagerEdgeCasesTest.t.sol`,
and `test/ai-generated/unit/idle/IdleDcaManagerTest.t.sol` also call these functions and will need their
call sites updated. Name any file beyond this list in the PR.

## Required tests

Lanes (all lanes run every test file):

- Targeted first: `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract StablecoinLendingTest -vv`.
- Then the full done-gate: `make check` (`forge build`, `make moc-none`, `make moc-layerbank`,
  `make moc-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-sovryn`, `make invariants-sovryn`).

Behaviors:

- A single pair withdraws that route and only that route; a second registered route on the same token is
  untouched.
- **The mixed case no longer over-calls.** With accrued balances on `(USDRIF, layerbank)` and
  `(DOC, sovryn)`, the paired call produces exactly two handler calls and none on `(DOC, layerbank)`.
  Assert on the third handler directly — `vm.expectCall` with count `0`, or the absence of its
  interest-withdrawn event — not merely on the user's resulting balance, which is equal either way.
- `tokens.length != routeIndexes.length` reverts `DcaManager__WithdrawalArraysLengthMismatch`.
- An unregistered pair in the middle of a valid list is skipped, and the pairs after it still execute.
- An idle route is skipped on the interest path; a zero rBTC balance is skipped on the rBTC path.
- A duplicated pair is harmless (the second pass finds nothing left to withdraw).
- Empty `tokens` and `routeIndexes` revert `DcaManager__EmptyWithdrawalArrays` on both functions,
  where they previously succeeded silently.
- `OperationsAdmin.isLendingRoute` is called once per pair, not once per combination. `vm.expectCall`
  with an explicit count on the two-token/two-route case is the direct assertion; the pre-change code
  makes four calls where the zipped form makes two.
- Interest still reaches the user for every named route that has accrued, with cash accounting unchanged.

Fork tests: this item adds no fork-specific assertions. `AGENTS.md` still requires **both**
`make fork-sovryn` and `make fork-tropykus` before push, with the exact commands documented in the PR.

## Success criteria

- [ ] Both functions consume positional `(token, routeIndex)` pairs; no nested loop remains.
- [ ] The mixed-route case calls only the handlers the user holds a position on, proven by a call-count or
      event assertion rather than a balance assertion.
- [ ] Mismatched lengths revert; unregistered, idle, and zero-balance pairs are still skipped rather than
      reverting.
- [ ] Empty arrays revert on both functions, matching `batchBuyRbtc`.
- [ ] `isLendingRoute` is called once per pair, asserted by call count rather than assumed from the shape.
- [ ] No `scheudule` spelling remains in `src/`.
- [ ] Done-gate (`make check`) passes, and both fork lanes pass before push.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: argument semantics change on `withdrawAllAccumulatedInterest` / `withdrawAllAccumulatedRbtc`
  (or two new selectors, per decision 1), plus two new errors —
  `DcaManager__WithdrawalArraysLengthMismatch()` and `DcaManager__EmptyWithdrawalArrays()`. No event
  change. The local-variable rename has no ABI surface.
- Scripts: none.
- Cutover: the frontend must send explicit pairs — one `tokens[i]` per `routeIndexes[i]` — and drops the
  unique-tokens/unique-indexes derivation added in BitChillRSK/front-end#14. Indexers are unaffected:
  `data-api`'s `InterestWithdrawal` entity and `bitchill-monitoring`'s backfill both consume handler events
  and neither decodes the withdraw-all calldata arrays.
- **Frontend follow-up required** (`AGENTS.md` **Frontend follow-up**). This PR changes an argument list
  and adds two custom errors on `DcaManager`, so the implementer opens or updates an issue on
  `bitChillRSK/front-end` in the same turn as opening the contracts PR and pastes the URL in the PR
  **Cutover / frontend note**. Search first: BitChillRSK/front-end#13 already scopes the cartesian API out
  to `dca-contracts` and is the natural place to comment rather than opening a duplicate. The issue body
  should name the old vs new call, and the files that still assume the cartesian form —
  `src/features/interest/utils/uniqueTokensAndProtocolIndexes.ts` (deleted), `InterestDashboard.tsx`, and
  `AccumulatedRbtcCard.tsx`.
- Behavior change beyond the signature: an empty-array call now reverts instead of succeeding as a no-op.
  Any caller that relied on sending empty arrays as a cheap no-op must stop; the relaunch frontend already
  guards against it before building the transaction.
- Ordering: must precede R9. Landing it after the freeze means re-freezing the ABI.
