# R54 — Top a schedule up from its accrued lending interest

Status: **not started** · Assigned: no · Optional/further-review: no

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

The real objection was never recorded and, until R53, was real: the function did not fit EIP-170.
Measured on prototype branch `proto/r12-compound-interest` (commit `7dd00fb`):

| Config | baseline | with the function | Δ | margin after |
| --- | --- | --- | --- | --- |
| optimizer off, no IR | 23,703 | 24,723 | +1,020 | **−147** (does not fit) |
| optimizer on, no IR | 13,767 | 14,367 | +600 | 10,209 |
| optimizer on, via IR | 11,039 | 11,547 | +508 | 13,029 |

**This PR is gated on [R53](./R53-optimizer-baseline.md).** Unoptimized it does not fit at all, and
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

## Scope

- [ ] `DcaManager.topUpFromInterest(address token, uint256 scheduleIndex, uint64 scheduleId)`:
      `external`, `nonReentrant` (`AGENTS.md` invariant 6 — it writes `s_dcaSchedules`),
      `validateScheduleIndex(msg.sender, token, scheduleIndex)`, keyed off `msg.sender` only, so it
      can reach nothing but the caller's own schedules.
- [ ] Validate `scheduleId` against storage (`_validateScheduleId`), then read `routeIndex` from the
      schedule and require a lending route (`_checkTokenYieldsInterest`).
- [ ] Credit `handler.getAccruedInterest(msg.sender, _lockedPrincipal(msg.sender, token, routeIndex))`.
      Reuse the exact figure the interest-withdrawal path uses; do not recompute it another way.
- [ ] Revert `DcaManager__NoInterestToTopUpWith(token, routeIndex)` when that figure is 0.
- [ ] Widen through `SafeCast.toUint128` when writing `tokenBalance`, matching `depositToken`.
- [ ] Emit `DcaManager__ScheduleToppedUpFromInterest(user, token, scheduleId, interest)` and the
      existing `DcaManager__TokenBalanceUpdated`. Index user, token, and scheduleId and nothing else
      (`AGENTS.md` invariant 4).
- [ ] Make **no** external state-changing call. No redeem, no mint, no transfer. The only external
      call is the `getAccruedInterest` view.
- [ ] Declare it on `IDcaManager` with user-facing natspec; implementation carries `@inheritdoc`.

## Out of scope

- [ ] Redeem-then-remint, or any per-schedule share accounting in a handler.
- [ ] Auto-compounding inside `batchBuyRbtc`, or splitting interest across several schedules.
- [ ] Changing `getAccruedInterest`, `_lockedPrincipal`, `withdrawInterest`, or the R15 lending-share
      dust deferral.
- [ ] Enabling the optimizer (R53 owns it) or `via_ir` / solx (R55).
- [ ] Refactoring the private helpers to share code with `depositToken` for bytecode reasons. With
      R53's margin there is no reason to touch audited hot-path code.

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
- [ ] `DcaManager` runtime growth is ~600 B under R53's settings, recorded in the PR with margin.
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
