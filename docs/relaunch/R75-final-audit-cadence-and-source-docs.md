# R75 — Final audit: no-catch-up cadence and concise source documentation

Status: **implemented** · GitHub [#134](https://github.com/BitChillRSK/dca-contracts/pull/134) ·
Assigned: yes · Optional/further-review: no · Order: stack on the current
source tip after R73 and the three review follow-ups (#131–#133), before any deployment

## Objective

Close the final protocol-wide audit with one cadence correction: a successful purchase skips every
missed slot and must leave the schedule ineligible for another purchase that UTC day. Record the
non-obvious but intentional security/accounting choices concisely in verified source, without version
history, ticket language, or claims that constructor-patched deployed bytecode is identical.

## Background

The UTC-day eligibility check is correct, but the timestamp update beneath it is not sufficient to
enforce the intended no-catch-up policy. Example: first weekly purchase Monday 23:00; miss the next
Monday; execute the following Monday 00:00. Raw elapsed seconds contain only one complete week, so the
current floor quotient advances the anchor to the missed Monday 23:00. The next due timestamp is then
the current Monday 23:00; its UTC day has already started, so a second same-day purchase is accepted.

The update must instead choose the latest cadence anchor whose UTC day has begun. Equivalently, compute
complete periods through the end of the current UTC day. The next anchor plus one period then falls on
a strictly later UTC day. This preserves the schedule's original time-of-day cadence: if a weekly bot
misses Monday and succeeds Tuesday, the anchor advances to Monday's slot and the next due day is the
following Monday. Only the execution price/time moves to Tuesday.

The audit also found no second exploitable accounting or external-call defect. Existing deliberate
choices remain: exact external receipt-share consumption with cash haircuts allowed; per-row ceiling
share debits and floor rBTC allocation dust; balance-delta cash; trusted, add-only handler wiring;
caller-only rBTC withdrawal; and an oracle floor without a tautological handler-generated deadline.
Those reasons should remain available where a reviewer meets the code, but shorter than the current
multi-paragraph form.

## Open product decisions

**none** — the human explicitly chose no catch-up and asked for the final audit/documentation pass.

## Scope

- [x] Change `DcaManager._rBtcPurchaseChecksEffects` so one successful purchase consumes all cadence
      slots whose due UTC day has started and the next due UTC day is strictly later than today.
- [x] Prove the missed-cycle/early-day counterexample, same-day rejection, multiple missed periods,
      and the weekly Monday-failure/Tuesday-success/next-Monday sequence with focused tests.
- [x] Document `lastPurchaseTimestamp` as a cadence anchor, not necessarily the execution timestamp;
      state the no-catch-up policy on `IDcaManager` without mentioning another protocol version.
- [x] Audit all first-party `src/` comments/NatSpec. Remove version-history/ticket language, replace
      Tropykus “legacy” labels with production-deployment facts, correct generic leaf “same bytecode”
      claims, and trim repetition while retaining durable security, accounting, authority, rounding,
      constructor-order, and external-integration reasons.
- [x] Remove the production-dead `_calculateFee` wrapper and have test harnesses call the existing
      loaded-settings helper directly. This has no ABI or deployed-runtime behavior effect.
- [x] Strengthen the canonical deployment test's assertions for immutable manager, stablecoin,
      venue, oracle/router, and receipt-token wiring where the current test checks only a subset.
- [x] Re-run Slither and Aderyn and update the release record only if their triage changes.
- [x] Add a concise auditor entry guide and align README, audit index, cutover prerequisites, and the
      R74 placeholder with the actual pre-mainnet handoff. This is the human-requested documentation
      drive-by after the source audit; it changes no contract, ABI, storage, or deployment behavior.

## Out of scope

- [ ] Fee/economics changes (R74), route-map changes, migration, upgradeability, rescue functions,
      handler flattening, or a new purchase/venue pause.
- [ ] New public functions, events, custom errors, indexed fields, storage fields, or constructor args.
- [ ] Supporting fee-on-transfer tokens, async/partial lending redemptions, or untrusted handlers.
- [ ] Rewriting historical specs/tests/docs merely because they legitimately record R-items or earlier
      behavior. The stand-alone wording rule applies to verified first-party `src/` comments/NatSpec.
- [ ] `forge fmt` of existing files or any live/testnet broadcast.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `src/FeeHandler.sol`
- Concise comment-only corrections in first-party `src/**`
- `test/unit/RbtcPurchaseTest.t.sol`
- `test/mocks/FeeHandlerHarness.sol`
- `test/unit/PurchaseUniswapMinOutTest.t.sol`
- `test/unit/deployment/FinalDeploymentTest.t.sol`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`
- `docs/relaunch/R73-RELEASE_RECORD.md` only if final analyzer triage changes
- `AUDIT_GUIDE.md`, `README.md`, `audits/README.md`, `docs/relaunch/CUTOVER_RUNBOOK.md`, and
  `docs/relaunch/R74-economics-parameters-revisit.md` for the auditor-handoff drive-by

## Required tests

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract RbtcPurchaseTest
SWAP_TYPE=dexSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=USDT0 \
  forge test --match-contract RbtcPurchaseTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract FinalDeploymentTest
make slither
make aderyn
make check
make check-deploy
make fork-sovryn
make fork-tropykus
make fork-dex-path
```

The cadence tests must fail against the pre-R75 formula. Fork tests add no cadence-specific assertion;
they remain the live integration gate before push.

All required commands passed. Slither exited with its expected nonzero finding status after reporting
89 triaged findings; Aderyn completed with the same retained categories. The two focused missed-cadence
regressions fail against the parent formula and pass with the corrected advancement.

## Success criteria

- [x] No schedule can complete two purchases in one UTC day, including after one or many missed slots.
- [x] A weekly schedule missed on Monday and bought Tuesday remains due the following Monday; no
      schedule drift or extra skip is introduced.
- [x] The verified source states that missed purchases are skipped and never recovered later.
- [x] First-party source comments contain no BitChill version comparison, relaunch wording, R-item id,
      or “legacy only” label, and the retained rationale is concise and accurate.
- [x] Audit/static-analysis findings are either fixed or explicitly retained with a current reason.
- [x] An auditor can identify the production scope, authority boundaries, asset/accounting flow,
      deliberate failure semantics, unsupported cases, reproducible gates, and outstanding human work
      from one stand-alone entry document.
- [x] The final ABI changes (one tuple component name, one event rename, one new error) are documented;
      function selectors and storage layout are unchanged, and deployment wiring assertions and gates pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Whole-day validation, maximum-width periods, same-day exclusion, and missed-slot advancement are
      covered at their boundaries.
- [ ] Tests in the PR match **Required tests** and the regression fails on the parent commit.
- [ ] Files beyond this list are limited to audited source-comment corrections or failing-test fallout
      and are named in the PR.
- [ ] No unrelated refactor or promotional security claim.

## ABI / deploy / cutover impact

- ABI: none from the base cadence fix above. `lastPurchaseTimestamp` keeps its type and event; its
  documented cadence rule becomes exact. See **Same-PR follow-up** below for the ABI-affecting rename
  that landed on top of this before merge.
- Storage: none.
- Scripts: none; canonical deployment tests gain assertions only.
- Cutover: the swapper and schedule readers must mirror the no-catch-up UTC-day rule. Existing matching
  consumer issues should be updated rather than duplicated. No broadcast action is performed here.

## Same-PR follow-up: UTC-midnight cadence grid and `cadenceAnchor` rename

A direct review of this fix's own field, done in the same PR before merge. `lastPurchaseTimestamp`
carried a **time of day** that eligibility never reads: the check only ever compares
`dayFloor(anchor + period)`, so for a whole-day period the anchor's time of day was dead weight — and
exactly the degree of freedom that made the fix above need its day-end trick in the first place. The
old anchor could also sit in the future (R2 called this intended), which the day-end formula had to
compensate for.

Two facts settle the simplification:

- The swapper runs at a fixed time of day, and eligibility opens at 00:00 UTC on the due day. The bot
  therefore has the whole due day to succeed or retry, and the anchor's time of day plays no part in
  that. This is what absorbed the 2026-09 lending-liquidity incident, where the morning tick failed and
  an evening retry succeeded with no slot lost.
- For a period that is a whole number of days, `dayFloor(anchor + period) == dayFloor(anchor) + period`.
  Snapping the anchor to UTC midnight is therefore **behaviour-preserving** for every period the
  protocol means to offer, not a semantic change.

### The no-catch-up policy itself was not new, and is reaffirmed

Skip-don't-recover has been the intent since `6335994` (2025-11-06), which replaced `anchor + period`
— a genuine catch-up design, where each purchase advanced exactly one period and a gap made the
schedule repeatedly eligible until it had made up every missed slot — with
`anchor + periodsElapsed * period`. R2 then explicitly preserved that snap. The fix above closed the
gap between the intent and its enforcement; this follow-up does not revisit the policy, but the
reasoning was never written down, so it is recorded here. Catch-up is rejected because:

- **It is structurally incompatible with one purchase per UTC day.** For a daily schedule, catching up
  a missed Monday *means* two purchases on Tuesday. One-per-day is what bounds batch size and makes
  per-tick gas predictable, which is what R64/R71–R73 optimised against.
- **Nothing is lost by skipping.** The stablecoin stays in `tokenBalance`; the schedule's tail extends
  by one slot. Total deployment over the schedule's life is unchanged — only the timing shifts.
- **Catch-up would not recover what was missed.** Two buys at one Tuesday price is one double-size buy.
  The volume comes back, the price diversification — the entire product — does not.
- **It would concentrate buying at the worst moments.** Outages correlate with market stress (a lending
  venue runs out of free liquidity precisely under withdrawal pressure), and every schedule shares the
  outage, so every schedule would catch up in the same tick.
- **It compounds failure.** `purchaseAmount > tokenBalance` reverts the whole batch, so larger catch-up
  debits make one under-funded row likelier to kill every other user's purchase in it.
- **It is unbounded.** A schedule paused six months and refunded would owe ~180 purchases, so it needs
  an arbitrary cap that becomes a new product parameter.

The liquidity incident that prompted the review is a **routing** problem, not a cadence one, and the
levers for it are same-day bot retry (which already worked), an idle-route fallback, and alerting on
venue free liquidity.

### Follow-up scope

- Snap the anchor to UTC midnight: a first purchase stamps `dayFloor(block.timestamp)` instead of
  `block.timestamp`, so every anchor is a grid point and no anchor is ever in the future.
- Require `purchasePeriod % 1 days == 0` on user schedules and on the protocol minimum, with a new
  `DcaManager__PurchasePeriodMustBeWholeDays` error. This is what keeps a schedule on the grid its
  anchor sits on; the pre-existing one-day floor stays.
- Replace the day-end formula with the exact one: eligibility is `dayFloor(now) >= anchor + period` and
  advancement is `anchor + ((dayFloor(now) - anchor) / period) * period`. The `periodsElapsed`
  floor-at-one and the `currentDayEnd` term both disappear as redundant.
- Rename `lastPurchaseTimestamp` → `cadenceAnchor` and `DcaManager__LastPurchaseTimestampUpdated` →
  `DcaManager__CadenceAnchorUpdated`. Widths, field order, and slot packing are unchanged.
- Keep the whole cadence computation inside one `unchecked` block and restore the safety justification
  this fix had removed.
- Start the shared local fixture at Monday 2026-01-05 09:00 UTC. Foundry's default timestamp floors
  to the zero sentinel; live forks retain their chain timestamp so lending markets never see time move
  backwards.
- Rework the boundary tests: the widest period is now the widest whole-day `uint32`, and the anchor's
  `uint48` edge is the first UTC midnight past `type(uint48).max`.
- Prove non-whole-day rejection on both the schedule setter and the protocol minimum, and keep a
  whole-day-but-not-whole-week (3-day) no-catch-up regression.

Out of scope: revisiting no-catch-up itself, fee/economics (R74), route maps, migration, or new public
surface beyond the one error and the two renames; calendar-month periods, which no whole-day grid can
express; sub-weekly cadence *policy* (whether the bot should run every 3 days, or Mondays and Fridays)
— the contract now permits any whole-day period, but which ones the product offers is a separate
decision recorded in R74.

### Semantics after the follow-up

For a schedule with anchor `A` (a UTC midnight) and period `P` (a whole number of days):

- **Eligible** from `A + P` at 00:00 UTC, and on every later day.
- **A successful purchase** sets `A' = A + floor((dayFloor(now) - A) / P) * P`, the newest grid point at
  or before today. It consumes its own slot plus every slot missed before it.
- **`A' + P` is always on a strictly later UTC day**, so a schedule cannot buy twice in one UTC day — now
  true by construction, since `A'` and `A' + P` are both grid points and `A' <= dayFloor(now)`.
- **`A'` is never in the future**, unlike the old anchor.
- **Cadence day-of-week survives a late execution after the first anchor**: an established weekly
  Monday schedule bought Tuesday stays due the following Monday. A first purchase establishes its
  cadence on the day it succeeds because no earlier anchor exists.

### Follow-up measurements

Controlled probe (same test file on both sides, warping to a fixed absolute instant):

| | before | after | delta |
|---|---|---|---|
| first purchase | 248,093 | 248,118 | +25 |
| subsequent purchase | 110,732 | 110,687 | **−45** |
| `DcaManager` runtime | 13,547 | 13,620 | +73 bytes |

The steady-state path — the one the protocol pays for every schedule, forever — is cheaper by one
`MOD`, one `SUB` and one `ADD`. The one-time first purchase pays 25 gas for the day-start snap.

### Follow-up ABI changes

Yes, and they are why this had to land in the same PR, before any deployment:

- `DcaSchedule.lastPurchaseTimestamp` → `cadenceAnchor` (tuple component name; width, position and
  packing unchanged).
- `DcaManager__LastPurchaseTimestampUpdated` → `DcaManager__CadenceAnchorUpdated` — a new event
  signature and topic0. No indexed field moved.
- New error `DcaManager__PurchasePeriodMustBeWholeDays`.

No function selector changes. The execution time of a purchase is unchanged for consumers: it is the
block timestamp of the log, which is where it always was — the anchor never carried it reliably,
because a purchase made late in its due day already reported an earlier value.

### Follow-up files touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `test/unit/DcaDappTest.t.sol` (fixture instant, shared `_utcDayStart` / `_expectedCadenceAnchor`)
- `test/unit/RbtcPurchaseTest.t.sol`, `test/unit/SchedulePackingTest.t.sol`,
  `test/unit/ModifiersTest.t.sol`
- Mechanical rename in the remaining first-party test files
- `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`

`test/gas/prototype/**` keeps `lastPurchaseTimestamp`: those are frozen R64 benchmark designs that
record an earlier shape, and this file's stand-alone-wording rule does not reach them.

### Follow-up tests run

```bash
make check
make check-deploy
make fork-sovryn
make fork-tropykus
make fork-dex-path
make slither      # 89 findings, unchanged from R73/R75 triage; retains its expected nonzero exit
make aderyn       # exit 0, same retained categories
```

Follow-up verification caught and fixed an unconditional fixture warp that rewound live forks and
caused lending-market setup underflows. Final fork results: Sovryn 410 passed / 0 failed / 30 skipped;
Tropykus 403 / 0 / 34; both Dex path runs 16 / 0 / 1.

### Follow-up consumer follow-ups

The field rename, the event rename and the anchor's new meaning all reach off-chain readers:

- [swapper-bot#11](https://github.com/BitChillRSK/swapper-bot/issues/11), [data-api#10](https://github.com/BitChillRSK/data-api/issues/10), [bitchill-monitoring#20](https://github.com/BitChillRSK/bitchill-monitoring/issues/20), [front-end#26](https://github.com/BitChillRSK/front-end/issues/26), [metrics-dashboard#8](https://github.com/BitChillRSK/metrics-dashboard/issues/8).

The rename is a **silent** break for any log filter keyed on the old topic0: a renamed event stops
matching rather than failing to decode, so every consumer issue calls that out explicitly.
