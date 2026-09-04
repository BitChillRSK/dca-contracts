# R64 — Re-examine the batch calldata shape and how schedules are keyed

Status: **measured, then implemented** · Assigned: yes · Optional/further-review: no

## Objective

Measure, and then decide, two coupled design choices on the purchase hot path that have never been
measured: whether `Batch`'s four parallel arrays earn their calldata, and whether
`s_dcaSchedules[user][token][index]` plus the index+id pair is the right way to address a schedule.
This is the last chance to change either before a deployment intended to run for years.

## Background

**The premise this item exists to test is wrong as currently implemented.** The four-array `Batch`
was introduced on the belief that reading schedule fields off-chain and passing them in saves
`SLOAD`s. It does not save any. `_batchBuyRbtc` calls `_rBtcPurchaseChecksEffects`, which loads the
whole `DcaSchedule` from storage regardless (`DcaSchedule memory dcaSchedule = dcaScheduleStorage`)
and then **compares** the loaded values against the passed ones, reverting on mismatch:

```solidity
if (schedulePurchaseAmount != batch.purchaseAmounts[i]) revert DcaManager__PurchaseAmountMismatch(...);
if (scheduleRouteIndex     != batch.routeIndex)         revert DcaManager__RouteIndexMismatch(...);
```

No storage read is skipped, and none can be: `tokenBalance` must be read to be debited, and
`lastPurchaseTimestamp` / `paused` share its slot, so slot 0 is unavoidable. `purchasePeriod` and
`scheduleId` are needed for validation and live in slot 1 alongside `purchaseAmount` and
`routeIndex`, so slot 1 is unavoidable too. Both slots are loaded whatever the calldata says.

`purchaseAmounts` and `routeIndex` are therefore **staleness guards, not gas optimisations**: they
make the batch revert cleanly if a user changed their schedule between the swapper's snapshot and
execution. That is a genuine and probably worth-keeping property — but it is a different property
from the one it was built for, and it should be priced as what it is.

**Storage shape.** `DcaSchedule` packs into exactly 2 slots (64/64 bytes used):

| slot | fields |
|---|---|
| 0 | `tokenBalance` u128 · `lastPurchaseTimestamp` u48 · `paused` bool |
| 1 | `purchaseAmount` u128 · `purchasePeriod` u32 · `routeIndex` u32 · `scheduleId` u64 |

The nested mapping carries `user` and `token` in the key for free, which is what buys that packing.
Per purchase row the current path costs three cold `SLOAD`s: the array length for
`validateScheduleIndex`, plus the two struct slots.

The alternative the audit raised is a flat `mapping(uint64 scheduleId => DcaSchedule)` with the
owner in the struct, so a batch row is just a `uint64` id. That trade is not obviously good and the
spec should not assume it is:

- **Wins.** Calldata drops from four words per row (~880 gas at typical values: buyer address,
  index, id, amount) to one mostly-zero word (~150 gas). The index+id pair collapses to one
  identifier, deleting `validateScheduleIndex`, the id cross-check, and the swap-pop-restores-an-id
  hazard the `ProtocolSettings` NatSpec currently has to warn about.
- **Losses.** A flat mapping must store `user` and `token` (40 bytes) that the nested key gives
  away. Even after dropping `scheduleId` from the struct (it becomes the key, −8 bytes) the struct
  is ~87 bytes, so **3 slots**. Two addresses plus two u128 amounts is already 72 bytes; only
  narrowing both amounts to u96 gets under 64, and that leaves no room for the timestamp, period,
  route index, and pause bit. Three slots is the realistic floor.
- **Net on the hot path** is therefore roughly a wash on storage (3 cold `SLOAD`s either way, since
  the length read disappears) and a clear win on calldata — but only if enumeration is solved
  without adding hot-path cost.
- **Enumeration is the real cost.** `getDcaSchedules(user, token)` and the max-schedules-per-token
  bound both need the per-user array. Keeping it alongside a flat mapping means `createDcaSchedule`
  and `deleteDcaSchedule` write to both structures. Those are cold paths — once per schedule, paid
  by the user — while the batch path runs every day forever and is paid by the protocol operator.
  That asymmetry is the argument for the change; quantify it before accepting it.

## Open product decisions

- [x] Is the staleness guard worth its calldata? **Answered: keep it.** Measured at 412 gas per row
      before the keying change and 452 after, not the ~240 estimated below.
- [x] Is a storage-layout change acceptable at all? **Answered: yes, implement it.** The measurement
      came first and the numbers were brought back before `src/` changed; the call was then made to
      take the flat key, on the ground that a deployment meant to run for years should carry the
      cheaper hot path. See **Implementation**.

## Scope

This item is **measurement first, implementation second**. Split into two PRs if the measurement
does not clearly favour a change. It was split: this is the measurement PR.

- [x] A gas benchmark of `batchBuyRbtc` at 1, 10, 50, and 200 rows on the current design, split
      into calldata cost, `SLOAD`/`SSTORE` cost, and handler cost. Record it in this file.
- [x] The same benchmark against a prototype flat-mapping branch, including the `createDcaSchedule`
      and `deleteDcaSchedule` regressions the flat design causes.
- [x] A decision recorded here, with numbers, even if the decision is "keep the current design".
- [x] Only then: the implementation, if the numbers justify it. Split into a second PR, and the
      shipped design is C **with the staleness guard kept** — see **Implementation** below.

## Out of scope

- [ ] Any change to the handler interface (`IPurchaseRbtc.batchBuyRbtc` takes buyers, ids, amounts,
      and `minRbtcOut`). If `DcaManager`'s calldata shape changes, the arrays it builds for the
      handler stay as they are.
- [ ] Changing `minRbtcOut` semantics, the oracle floor, or the purchase-period cadence logic.
- [ ] Any other R-item's work.

## Files likely touched

Measurement PR: `test/gas/` (the benchmark, a stub handler, and the two prototypes) plus the one
`src/` comment the success criteria require regardless of the decision — the `Batch` NatSpec in
`src/interfaces/IDcaManager.sol`. That edit is provably comment-only: metadata-stripped runtime is
byte-identical on all ten deployable contracts.

Implementation PR, if it happens: `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`, and every
test that constructs a `Batch` or calls a schedule mutator by index.

## Required tests

- [x] The benchmark itself, checked in and runnable, so the numbers can be reproduced rather than
  trusted: `test/gas/R64BatchGasBenchmark.t.sol`, three tests, one of which asserts the prototypes
  still reproduce `DcaManager` rather than trusting that they do.
- `make check` under **`[profile.default]`** — the measurement basis in
  [`README.md`](./README.md) — and separately under `FOUNDRY_PROFILE=deploy`, since R60 made
  via-IR the profile that ships and the two can disagree on hot-path codegen. Report both.
- If the implementation lands: `make fork-sovryn`, `make fork-tropykus`, `make check-deploy`.

## Success criteria

- [x] A gas table in this file covering both designs at four batch sizes, under both profiles.
      Three designs, not two: the staleness guard needed its own prototype to be priced separately
      from the keying.
- [x] The `AGENTS.md` invariant "the schedule index is a position and the id is a creation nonce"
      is either still true or explicitly replaced by a stated alternative. Still true: invariant 7
      is untouched, and nothing in this PR changes `src/` behavior.
- [x] If nothing changes, the `Batch` NatSpec in `IDcaManager` says the cross-check fields are a
      staleness guard and **not** a storage-read saving, so the next reader does not rediscover
      this from scratch.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Every gas number states its profile and its batch size.
- [ ] Any storage-layout change is justified against the cold-path regression it causes, not only
      against the hot-path win.
- [ ] Protocol invariants in `AGENTS.md` still hold, or the spec says which one changed and why.
- [ ] If the decision is to keep the current design, the misleading rationale is corrected in the
      NatSpec anyway — that part ships regardless.

## ABI / deploy / cutover impact

- ABI: potentially large. `Batch` is an ABI struct, and dropping arrays from it changes the
  swapper's encoding. Every schedule mutator takes `(scheduleIndex, scheduleId)` today; collapsing
  to one id changes seven external signatures.
- Scripts: none for the measurement PR.
- Cutover: if the implementation lands, the swapper service and the frontend both change. File
  consumer issues on both sibling repos before merging, per `AGENTS.md`. **This item cannot land
  after the relaunch deploy** — say so in the PR.

---

## Measurements

Reproduce with, from a clean tree:

```
forge test --match-path 'test/gas/*' -vv
FOUNDRY_PROFILE=deploy forge test --match-path 'test/gas/*' -vv
```

`test/gas/R64BatchGasBenchmark.t.sol` prices three designs against one stub handler and identical
schedules:

| | storage | a batch row is |
|---|---|---|
| **A** | today's `s_dcaSchedules[user][token][index]` | buyer, index, id, amount |
| **B** | A's, unchanged | buyer, index, id |
| **C** | flat `mapping(uint64 => …)` | id |

A is `src/DcaManager` itself, not a copy of it. B and C are test-only prototypes under
`test/gas/prototype/`, reproducing A's checks, effects and events field for field. B keeps A's
storage and cold paths exactly, so `test_r64_createAndDeleteGas` asserts B's create and delete stay
within a few percent of A's — if the prototypes stop reproducing the contract, the benchmark fails
rather than quietly measuring something else. They match within 264 gas on create (0.3%).

### What the columns are

`calldata` is the intrinsic transaction cost of the exact bytes a swapper would send. A test calling
a contract never pays it and a swapper sending a transaction always does, so it is computed from the
encoded bytes and added back by hand. **Rootstock does not price calldata the way Ethereum does**,
and this was measured rather than assumed — `eth_estimateGas` on a plain transfer carrying `n` zero
and then `n` non-zero bytes, against mainnet:

| bytes | 0 | 100 | 200 | 1000 | 2000 |
|---|---|---|---|---|---|
| zero bytes | 21,060 | +448 | +884 | +4,384 | +8,756 |
| non-zero bytes | 21,060 | +1,648 | +3,284 | +16,384 | +32,756 |

Non-zero minus zero is exactly 12 gas per byte at every size, which fixes the pair at EIP-2028's
16/4 rather than the pre-Istanbul 68/4. The remainder over 4 and 16 per byte is `12 × ceil(bytes/32)`
at all four sizes — 48, 84, 384, 756 — a per-word charge with no Ethereum equivalent. Base
transaction cost is 21,060, not 21,000. A calldata figure computed from Ethereum's schedule
understates Rootstock by about 8%.

`handler` is the stub's leg, measured separately at the same length and identical across the three
designs by construction; `manager` is `exec − handler`, the schedule bookkeeping the design actually
changes; `total` is `calldata + exec`, the operator's bill.

### `batchBuyRbtc`, steady-state tick, `[profile.default]`

| design | rows | bytes | calldata | exec | handler | manager | total | per row |
|---|---|---|---|---|---|---|---|---|
| A | 1 | 516 | 3,024 | 27,747 | 6,123 | 21,624 | 30,771 | 30,771 |
| A | 10 | 1,668 | 10,956 | 187,456 | 8,868 | 178,588 | 198,412 | 19,841 |
| A | 50 | 6,788 | 46,256 | 907,029 | 33,651 | 873,378 | 953,285 | 19,065 |
| A | 200 | 25,988 | 178,820 | 3,617,483 | 128,591 | 3,488,892 | 3,796,303 | **18,981** |
| B | 1 | 420 | 2,484 | 24,992 | 6,123 | 18,869 | 27,476 | 27,476 |
| B | 10 | 1,284 | 8,532 | 184,584 | 8,868 | 175,716 | 193,116 | 19,311 |
| B | 50 | 5,124 | 35,352 | 897,047 | 33,651 | 863,396 | 932,399 | 18,647 |
| B | 200 | 19,524 | 136,104 | 3,577,712 | 128,591 | 3,449,121 | 3,713,816 | **18,569** |
| C | 1 | 228 | 1,344 | 23,513 | 6,123 | 17,390 | 24,857 | 24,857 |
| C | 10 | 516 | 2,712 | 173,891 | 8,868 | 165,023 | 176,603 | 17,660 |
| C | 50 | 1,796 | 8,792 | 844,332 | 33,651 | 810,681 | 853,124 | 17,062 |
| C | 200 | 6,596 | 31,664 | 3,367,848 | 128,591 | 3,239,257 | 3,399,512 | **16,997** |

### `batchBuyRbtc`, steady-state tick, `FOUNDRY_PROFILE=deploy` (via-IR, what ships)

| design | rows | calldata | exec | handler | manager | total | per row |
|---|---|---|---|---|---|---|---|
| A | 1 | 3,024 | 26,045 | 5,664 | 20,381 | 29,069 | 29,069 |
| A | 10 | 10,956 | 177,521 | 8,030 | 169,491 | 188,477 | 18,847 |
| A | 50 | 46,256 | 860,058 | 31,135 | 828,923 | 906,314 | 18,126 |
| A | 200 | 178,820 | 3,425,635 | 119,780 | 3,305,855 | 3,604,455 | **18,022** |
| B | 1 | 2,484 | 23,196 | 5,664 | 17,532 | 25,680 | 25,680 |
| B | 10 | 8,532 | 173,716 | 8,030 | 165,686 | 182,248 | 18,224 |
| B | 50 | 35,352 | 843,195 | 31,135 | 812,060 | 878,547 | 17,570 |
| B | 200 | 136,104 | 3,360,975 | 119,780 | 3,241,195 | 3,497,079 | **17,485** |
| C | 1 | 1,344 | 22,033 | 5,664 | 16,369 | 23,377 | 23,377 |
| C | 10 | 2,712 | 164,554 | 8,030 | 156,524 | 167,266 | 16,726 |
| C | 50 | 8,792 | 798,665 | 31,135 | 767,530 | 807,457 | 16,149 |
| C | 200 | 31,664 | 3,186,486 | 119,780 | 3,066,706 | 3,218,150 | **16,090** |

The two profiles agree on direction and rank at every size. via-IR takes about 5% off every design
without moving the gaps much.

### Cold paths, one schedule, paid by the user

| design | create (default) | delete (default) | create (deploy) | delete (deploy) |
|---|---|---|---|---|
| A | 91,622 | 11,122 | 90,884 | 10,595 |
| B | 91,358 | 10,850 | 89,535 | 10,560 |
| C | **135,925** | 11,620 | **133,797** | 11,227 |

## What the numbers say

**The premise this item was opened to test is confirmed wrong, and the correction is bigger than the
spec assumed.** Passing schedule fields in calldata saves no `SLOAD`. Both designs read exactly three
cold slots per row — A reads the array length plus the two struct slots, C reads three struct slots —
so the storage side is a wash, exactly as the background predicted.

**But the calldata framing was wrong too, in C's favour.** At 200 rows C saves 1,984 gas per row over
A, and only 736 of that is calldata; the other 1,248 is execution. Storage reads being equal, that
execution saving is decoding four calldata arrays instead of one, copying three of them into memory
for the handler call, the nested mapping's three `keccak256` per row against a flat key's one, and the
`validateScheduleIndex` and `_validateScheduleId` checks a flat key deletes outright. Calldata is only
4.7% of A's bill at 200 rows. **The case for design C is not the one it was raised on.**

**The staleness guard costs 412 gas per row** (default; 537 under via-IR), not the ~240 estimated —
201 of calldata and 199 of execution, and 2.2% of a row's total cost.

**Scale.** At the repo's basis of ~2,300 gas ≈ $0.014, one gas is about $6.1e-6:

- C saves **$0.0121 per schedule per tick**, and costs the *user* **$0.273 once** at create
  (+44,303 gas on create, +498 on delete). Break-even is **22.6 purchases** — 23 days for a daily
  schedule, after which C is ahead for that schedule forever.
- A schedule purchasing daily for a year: the operator saves **$4.41**; the user paid $0.27 once.
- The guard costs the operator **$0.0025 per row per tick**: $0.92 per schedule-year.
- Rootstock's block gas limit is 10,000,000 (measured at block 9,210,661), so one tick fits about
  **525 rows under A and about 585 under C** — a real but not decisive operational difference.

## Decision

**Gate 1 — keep the `purchaseAmounts` staleness guard.** 412 gas per row is 2.2% of a row, and what it
buys is that a user editing a schedule between the swapper's snapshot and the tick produces a named
revert instead of a purchase at an amount nobody quoted. The one argument against it that the numbers
raise is not gas: with the guard, one stale row reverts the *whole* batch, so a single user's edit can
cost the operator a tick. That is a liveness cost the bot already carries for `SchedulePaused`, and it
is filterable the same way. Keep it, and the NatSpec now says what it is — that part ships in this PR
regardless of anything else here.

**Gate 2 — the flat key ships.** The recommendation from the measurement was to keep the nested
design; the decision was to take the flat one, on the ground that the hot path is paid every day for
years and this is the last moment it can be changed. The measurement's own reasoning against it was
about timing and blast radius, never about the gas, and those are the costs the change actually pays.
What follows is the argument the measurement made against, kept as written, and then what shipped.

**The case the measurement made for keeping design A.** The numbers
justify C on gas alone: 10.5% off every tick, break-even in 23 days, and it collapses the index+id pair
into one identifier, deleting `validateScheduleIndex`, the id cross-check, and the swap-pop-reminting
hazard invariant 7 exists to warn about. What it costs is not gas:

- Seven external signatures change, and five consumer repos with them. The swapper bot and the front
  end both get rewritten against a new addressing model.
- `purchaseAmount` narrows from `uint128` to `uint96` (~7.9e10 tokens at 18 decimals). Keeping
  `uint128` splits a purchase's two writes across two slots and gives back more than the calldata wins.
- The struct grows from exactly two slots to three, and create costs the user 48% more.
- Enumeration duplicates: create and delete each write two structures, and delete gains a linear scan.
- It is a storage redesign landing after the entire relaunch review stack has been audited against the
  current one, with no round left to audit it in.

Against that, the whole prize at relaunch scale is about $4.41 per schedule-year. At 200 active daily
schedules that is roughly $880 a year, against a rewrite of the swapper's and the front end's core
addressing at the last moment before cutover.

Invariant 7 in `AGENTS.md` — the public `scheduleId` is the creation nonce, never array state — is
unchanged either way, and still holds: ids still come from a strictly increasing counter, and the
per-owner id list still swap-pops, which is exactly the hazard that invariant exists to name.

---

## Implementation

Shipped: the flat key, with the `purchaseAmounts` staleness guard kept. That is design C plus gate 1's
answer, so it is not the C the measurement priced — the guard buys back 452 gas per row of C's saving,
and the numbers below are of what actually shipped rather than of the prototype.

### Storage

`mapping(uint64 scheduleId => DcaSchedule)`, plus `mapping(address user => mapping(address token =>
uint64[]))` for enumeration. `DcaSchedule` is three slots, ordered so that slot 0 still holds every
field a purchase reads or writes and a purchase is still one `SSTORE`:

| slot | fields | bytes used |
|---|---|---|
| 0 | `tokenBalance` u128 · `lastPurchaseTimestamp` u48 · `paused` · `purchasePeriod` u32 · `routeIndex` u32 | 31 of 32 |
| 1 | `user` · `purchaseAmount` u96 | 32 of 32 |
| 2 | `token` · `scheduleId` u64 | 28 of 32 |

Two consequences are worth stating plainly. **`purchaseAmount` narrows from `uint128` to `uint96`**,
capping one purchase at ~7.9e10 tokens at 18 decimals; `tokenBalance` keeps `uint128`. At `uint128` the
amount no longer fits beside an address, which splits a purchase's two writes across two slots and
gives back more than the narrower field ever saves. **`scheduleId` stays in the struct** even though it
duplicates the key: it costs no extra slot, and without it `getDcaSchedules` would hand a caller
schedules it could not then address.

### Surface

Eight external signatures drop `(token, scheduleIndex)` and take the id alone: `depositToken`,
`withdrawToken`, `withdrawTokenAndInterest`, `deleteDcaSchedule`, `updatePurchaseAmount`,
`updatePurchasePeriod`, `setSchedulePaused`, `topUpFromInterest`. `getDcaSchedule(user, token, index)`
becomes `getDcaSchedule(uint64 scheduleId)`. `createDcaSchedule` and `getDcaSchedules(user, token)` are
unchanged. `Batch` loses `buyers` and `scheduleIndexes` and is now
`{uint64[] scheduleIds; uint256[] purchaseAmounts; address token; uint256 routeIndex; uint256 minRbtcOut}`
— the manager builds the buyer list from what each schedule says it belongs to, so a batch can no
longer assert a buyer at all. `IPurchaseRbtc.batchBuyRbtc` is untouched, as **Out of scope** required.

### The check the mapping key used to make for free

This is the change's one real hazard and it is worth naming: `s_dcaSchedules[msg.sender][token][index]`
could not address another account's schedule, because the caller was the key. A flat key can address
anything, so ownership became a stored field and an explicit check on every path —
`DcaManager__InexistentSchedule` for an unknown id, `DcaManager__NotScheduleOwner` for somebody else's.
One omission is another account's funds. `AGENTS.md` invariant 8 now states it, and
`test/unit/ScheduleOwnershipTest.t.sol` walks the whole mutator surface rather than a sample: every
mutator against a stranger's id, every mutator against an id belonging to nobody, id zero, and a check
that a refused stranger left the schedule byte-for-byte as it was. The purchase path is `onlySwapper`
and buys for the schedule's stored owner, so it instead checks existence and that the schedule's token
matches the batch's — without that, a row could name a schedule of another stablecoin and have it
debited by a handler that never holds its funds (`DcaManager__ScheduleTokenMismatch`).

### What it cost and bought

`batchBuyRbtc`, 200 rows, total per row including intrinsic calldata. B is the pre-R64 keying,
reproduced as a prototype and pinned to the figures the real contract measured before the change:

| | default | via-IR (ships) |
|---|---|---|
| B — pre-R64 nested keying | 18,918 | 17,736 |
| **A — shipped** | **17,448** | **16,535** |
| C — flat, guard dropped | 16,996 | 16,090 |

The change takes **1,470 gas per row** off the tick under `[profile.default]` and **1,201** under
via-IR, which is 7.8% and 6.8%. Calldata for a 200-row batch falls from 25,988 bytes to 13,060 —
half, not more, because `purchaseAmounts` stayed. The guard costs 452 gas per row of what was
available.

Cold paths, per schedule, paid by the user:

| | create (default) | delete (default) | create (via-IR) | delete (via-IR) |
|---|---|---|---|---|
| B — pre-R64 | 91,358 | 10,835 | 89,524 | 10,486 |
| **A — shipped** | **136,475** | **11,838** | **134,845** | **11,897** |

Create costs the user **49% more** — 45,117 gas, about $0.28 once — and delete about 1,000 gas more for
the id-list scan. Break-even is **31 purchases** under `[profile.default]` and **39** under via-IR, so
a daily schedule pays for its own create inside about six weeks and is ahead for the rest of its life.

`DcaManager`'s metadata-stripped runtime went **14,492 → 13,646 bytes**, 846 smaller: the flat key
deletes `validateScheduleIndex`, the id cross-check and the nested addressing. Every deployable
handler is byte-identical, since none of them reads the schedule shape.

### What did not change

Ids are still the creation nonce from a strictly increasing counter, still start at 1, and are still
retired by deletion rather than reused (invariant 7). Every external function that writes
`s_dcaSchedules` still carries `nonReentrant` as its first modifier, with the two `onlySwapper`
purchase paths the same documented exception (invariant 6). Events keep their signatures and indexed
fields; the errors that carried a `scheduleIndex` dropped that field, and two errors are new.
