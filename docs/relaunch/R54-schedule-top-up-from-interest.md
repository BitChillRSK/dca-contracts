# R54 — Top a schedule up from its accrued lending interest

Status: **implemented** · Assigned: yes (PR 56) · Optional/further-review: no

## Objective

Add one `DcaManager` entry point that credits a user's accrued lending interest to a schedule's
spendable `tokenBalance`, so yield buys more rBTC instead of having to be withdrawn to the wallet
and deposited back. No tokens move: the funds already sit in the lending position, and the call only
raises that schedule's claim over them.

## Background

This is the revival of **R12**, which was specified during planning and then closed without
implementation. Two things about that closure were wrong.

The recorded reason — "an in-handler compound path couples principal/share accounting to a chosen
schedule and adds a new cash-moving entry point to immutable handlers" — describes a design that was
never proposed. The specified design is `DcaManager`-only, makes no handler call, moves no cash, and
explicitly forbids redeem-then-remint. It was rejected against a strawman.

The real objection was never recorded and, until the optimizer pin, was real: the function did not fit EIP-170.
Measured on prototype branch `proto/r12-compound-interest` (commit `7dd00fb`):

| Config | baseline | with the function | Δ | margin after |
| --- | --- | --- | --- | --- |
| optimizer off, no IR | 23,703 | 24,723 | +1,020 | **−147** (does not fit) |
| optimizer on, no IR | 13,767 | 14,367 | +600 | 10,209 |
| optimizer on, via IR | 11,039 | 11,547 | +508 | 13,029 |

**This PR is gated on the optimizer pin in [#104](https://github.com/BitChillRSK/dca-contracts/pull/104).** Unoptimized it does not fit at all, and
stripping the dedicated event saves only 112 bytes — not enough to rescue it. With the optimizer on
it costs 600 bytes against ~10.8 KB of margin.

Why the accounting is safe. Interest is pooled per user × token × route, not per schedule:
`getInterestAccrued` is `handler.getAccruedInterest(user, _lockedPrincipal(user, token, routeIndex))`,
and `_lockedPrincipal` sums `tokenBalance` across that user's schedules on that route. Crediting
exactly that figure raises the route's summed principal to the position's floored value and no
higher, leaving accrued interest at ~0. That is the same end state an interest *withdrawal* already
produces, reached from the other side and without touching the lending protocol — which is also why
it avoids Sovryn's SIP-0094 exit fee that the withdraw-then-deposit route pays.

The two-transaction path (`withdrawAllAccumulatedInterest` then `depositToken`) stays; this is
strictly cheaper and strictly fewer steps, not a replacement.

## Open product decisions

1. **Does the R48 deposit pause block a top-up?** `depositToken` and `createDcaSchedule` resolve
   through `_handlerForDeposit`, which reverts `DcaManager__DepositsPaused`. A top-up pulls no
   tokens in but does raise DCA-spendable principal on that route. R12 predates R48 and has no
   answer. Recommend **respecting the pause** (resolve through `_handlerForDeposit`): governance
   pausing deposits on a route means "stop growing exposure here", and the source of the funds does
   not change that. The opposite reading — a pause is about intake and this moves nothing in — is
   defensible; the human decides.
2. **Function and event naming.** The planning name was `compoundInterest`. Recommend
   **`topUpFromInterest`** and `DcaManager__ScheduleToppedUpFromInterest`: "compound" collides with
   Compound the lending protocol, which this codebase names constantly (Tropykus forks it, and
   `IMPLEMENTATION_ORDER.md` / R27 / R28 all discuss "Compound return codes"). Same class of
   collision R26 fixed when it retired "lending token" for "shares".
3. **All-or-part.** R12 credits *all* accrued interest to the chosen schedule with no `amount`
   parameter. Recommend keeping that — an `amount` costs bytes and calldata for a case nobody has
   asked for, and partial top-ups remain reachable by topping up and withdrawing the difference.

### Answered 2026-09-02

1. **The pause blocks a top-up.** Resolve through `_handlerForDeposit`. Both helpers return the same
   handler at the same one call site, so the choice cost no code either way and the recommendation
   stood: a paused route means stop growing DCA exposure there, whatever funds it. Nothing is
   stranded — the withdraw and delete paths never consult the pause.
2. **`topUpFromInterest`**, with `DcaManager__ScheduleToppedUpFromInterest` and
   `DcaManager__NoInterestToTopUpWith`, as recommended.
3. **Part, not all: the function takes an `amount`.** Decided against the recommendation, because one
   pot of route interest feeding two schedules is a case the product does want, and reaching it by
   crediting one schedule and withdrawing the difference pays the redemption fee this feature exists
   to avoid. `amount` is bounded above by the accrued figure and below by a rule the human specified:
   the credit must raise the schedule past its **next whole purchase**
   (`(tokenBalance + amount) / purchaseAmount > tokenBalance / purchaseAmount`), so interest cannot be
   moved across in dust, and a schedule holding 10.5 purchases needs only half a purchase amount
   rather than a full one. A flat `amount >= purchaseAmount` floor was rejected in the same exchange:
   it would strand any interest smaller than one purchase.

## Scope

- [x] `DcaManager.topUpFromInterest(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 amount)`:
      `external`, `nonReentrant` (`AGENTS.md` invariant 6 — it writes `s_dcaSchedules`),
      `validateScheduleIndex(msg.sender, token, scheduleIndex)`, keyed off `msg.sender` only, so it
      can reach nothing but the caller's own schedules. The `amount` is decision 3's answer.
- [x] Validate `scheduleId` against storage (`_validateScheduleId`), then read `routeIndex` from the
      schedule and require a lending route (`_checkTokenYieldsInterest`).
- [x] Resolve the handler through `_handlerForDeposit` (decision 1), so a paused route reverts
      `DcaManager__DepositsPaused`.
- [x] Bound the credit by `handler.getAccruedInterest(msg.sender, _lockedPrincipal(msg.sender, token, routeIndex))`.
      Reuse the exact figure the interest-withdrawal path uses; do not recompute it another way.
- [x] Revert `DcaManager__NoInterestToTopUpWith(token, routeIndex)` when that figure is 0, and
      `DcaManager__TopUpExceedsAccruedInterest(token, routeIndex, amount, accruedInterest)` when the
      request is larger than it.
- [x] Revert `DcaManager__TopUpDoesNotFundAnotherPurchase(token, scheduleId, amount)` unless the
      credit raises the balance past its next whole purchase. A zero `purchaseAmount` schedule can
      never clear that bar, which also keeps the comparison off a division by zero.
- [x] Widen through `SafeCast.toUint128` when writing `tokenBalance`, matching `depositToken`.
- [x] Emit `DcaManager__ScheduleToppedUpFromInterest(user, token, scheduleId, interest)` and the
      existing `DcaManager__TokenBalanceUpdated`. Index user, token, and scheduleId and nothing else
      (`AGENTS.md` invariant 4).
- [x] Make **no** external state-changing call. No redeem, no mint, no transfer. The only external
      call is the `getAccruedInterest` view.
- [x] Declare it on `IDcaManager` with user-facing natspec; implementation carries `@inheritdoc`.

## Out of scope

- [x] Redeem-then-remint, or any per-schedule share accounting in a handler.
- [ ] Auto-compounding inside `batchBuyRbtc`, or one call splitting interest across several
      schedules. Decision 3 reaches several schedules by calling the function once per schedule;
      each call still credits exactly one.
- [x] Changing `getAccruedInterest`, `_lockedPrincipal`, `withdrawInterest`, or the R15 lending-share
      dust deferral.
- [x] Enabling the optimizer ([#104](https://github.com/BitChillRSK/dca-contracts/pull/104) owns it), re-baselining the recorded numbers (R53), or `via_ir` / solx (R55).
- [x] Refactoring the private helpers to share code with `depositToken` for bytecode reasons. With
      the optimized margin there is no reason to touch audited hot-path code.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `test/unit/` — a new suite for this entry point; `test/ai-generated/unit/` for handler-side
  assertions if the interest figure needs cross-checking per protocol.

A working reference implementation of the happy path exists on `proto/r12-compound-interest`
(`7dd00fb`). It is a size probe with **no tests** and uses the planning-era names; treat it as
evidence for the measurements above, not as the shipped shape.

## Required tests

Run on the lending lanes, since idle routes have no interest to credit:

- `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-path 'test/unit/<NewSuite>.t.sol' -vv`
- The same with `LENDING_PROTOCOL=layerbank` and `LENDING_PROTOCOL=tropykus`.
- Full done-gate per `AGENTS.md`, plus `make fork-sovryn` and `make fork-tropykus` before push.

Behaviors to assert:

- Top-up raises the chosen schedule's `tokenBalance` by exactly the pre-call `getInterestAccrued`,
  and the reported accrued interest afterwards is ~0.
- **No lending `mint` / `burn` / `redeem` and no token transfer occur in the transaction.** Assert on
  mock call counts, not just on balances.
- Other schedules on the same route keep their `tokenBalance`; only the named one moves.
- A subsequent `batchBuyRbtc` can spend the newly credited balance, including the case where the
  schedule was depleted and resumes.
- Reverts: zero accrued interest; idle route (`DcaManager__TokenDoesNotYieldInterest`); mismatched
  `scheduleId`; out-of-range `scheduleIndex`; another user's schedule is unreachable.
- **Boundary after top-up.** The route's summed `tokenBalance` now equals the position's floored
  value. Assert that `withdrawToken` with the `type(uint256).max` sentinel still exits cleanly and
  that `deleteDcaSchedule` still pays out — share debits round up and clamp to shares held, so this
  is the case most likely to surface a 1-wei shortfall.
- `withdrawAllAccumulatedInterest` after a full top-up is a no-op that does not revert.
- Whichever answer decision 1 takes, a test pins it: deposits paused → top-up reverts, or succeeds.

## Success criteria

- [ ] All of the above passes on all three lending lanes.
- [ ] `DcaManager` runtime growth is ~600 B under the optimized no-IR profile, recorded in the PR with margin.
- [ ] No handler contract changed.
- [ ] No external state-changing call on the new path.
- [ ] Open product decisions 1–3 are answered in the PR body, not left implicit in the code.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] `AGENTS.md` invariants hold: 4 (indexing), 6 (`nonReentrant` on a `s_dcaSchedules` writer),
      and 7 (`scheduleId` is the creation nonce, validated not derived).
- [ ] The credited figure is the same expression the withdrawal path uses.
- [ ] No `src/` comment names an R-id (`AGENTS.md` **Onchain comments**).
- [ ] Tests in the PR match **Required tests**, including the no-external-call and boundary cases.

## ABI / deploy / cutover impact

- ABI: **additive** — one new function, one new event, one new error. R9 froze the surface, but R51
  and R52 both changed selectors after that freeze, so the freeze is a cutover cost here, not a bar.
- Scripts: none.
- Cutover: consumers must learn the new entry point and event. Open or update issues on
  `front-end` (surface "top up from interest" alongside the existing withdraw-interest flow),
  `data-api` and `bitchill-monitoring` (index the new event; a balance increase with no matching
  ERC-20 transfer is otherwise indistinguishable from a deposit).
