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

- [x] Is the staleness guard worth its calldata? **Answered: drop it.** Measured at 412 gas per row on
      the old keying and ~450 on the new one, not the ~240 estimated below — and what it bought was
      turning one user's edit into a failed tick for every other row in the batch. See
      **Implementation**.
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

- ABI: large, and it landed. `Batch` is an ABI struct and now carries one array instead of four, which
  changes the swapper's encoding. Eight schedule mutators went from `(token, scheduleIndex,
  scheduleId)` to `(token, scheduleId)`, `getDcaSchedule` is now keyed by `(token, scheduleId)`, and
  `getDcaSchedules` returns the ids in a parallel array beside the structs.
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

`test/gas/R64BatchGasBenchmark.t.sol` prices every design considered, against one stub handler and
identical schedules, at 1, 10, 50 and 200 rows:

| | storage | a batch row is |
|---|---|---|
| **A** | `src/DcaManager` as it now ships: `s_dcaSchedules[token][scheduleId]` | id |
| **B** | pre-R64: `s_dcaSchedules[user][token][index]` | buyer, index, id, amount |
| **C** | flat `mapping(uint64 => …)`, owner and token stored, three slots | id |
| **D** | A's storage with the per-row amount guard restored | id, amount |
| **E** | A's design keyed the other way round, `[scheduleId][token]` | id |
| **F** | flat by id, a `uint32 routeId` in place of the token address | id |
| **G** | `[scheduleId][user][token]`: both halves structural | buyer, id |
| **H** | G's key with the row packed into one word, `(id << 160) | buyer` | packed word |
| **I** | `[user][token][scheduleId]`: the pre-R64 key with the index replaced by the id | buyer, id |

A is `src/DcaManager` itself, not a copy of it. The rest are test-only prototypes under
`test/gas/prototype/`, reproducing A's checks, effects and events field for field, so a design's row
differs from A's only where its design does. B keeps the pre-R64 storage and cold paths exactly, and
`test_r64_createAndDeleteGas` pins its create against the figure the real contract measured before the
change — if the prototypes stop reproducing the contract, the benchmark fails rather than quietly
measuring something else. `test_r64_designsAgreeOnEffects` asserts every design debits the same
schedule by the same amount, so the table compares like with like.

Registry access is measured rather than held out: every (design, size) pair gets its own token,
handler and route record, so each measured batch reads a registry slot that is cold, as the first
batch of a real transaction does. An earlier version of this file pre-warmed the registry for every
design, which silently handed the `routeId` design its second slot read for free — and because the
whole benchmark is one transaction, that design's first batch then left the slot warm for every size
that followed. The tables below and in **Implementation** are the corrected ones.

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

### Results

The full per-row tables for all nine designs, under both profiles, are in **Implementation → What it
cost and bought** below, together with the cold paths. They supersede the three-design tables this
section carried while the measurement PR was open: those were taken with a pre-warmed registry and
with only A, B and C built.

The headline, at 200 rows under via-IR, the profile that ships: **17,746 gas per row before R64,
14,188 after** — 20.0% off every row of every tick, of which 4,143 is calldata the swapper no longer
sends and the rest is execution.

## What the numbers say

**The premise this item was opened to test is confirmed wrong.** Passing schedule fields in calldata
saves no `SLOAD`. The pre-R64 design (B) read three cold slots per row — the array length plus the two
struct slots — and the shipped design reads two, because the id addresses the value directly. The
calldata those fields cost was never buying a storage read; it was buying a comparison against a value
the contract had already loaded.

**Calldata was not where most of the win was either.** At 200 rows under via-IR the shipped design
saves 3,558 gas per row against pre-R64, of which 4,143/200 ≈ 736 is intrinsic calldata. The rest is
execution: decoding one calldata array instead of four, copying one fewer into memory for the handler
call, one `keccak256` per row fewer than a three-level key, and the `validateScheduleIndex` and id
cross-check that an id-addressed schedule deletes outright.

**The staleness guard costs about 450 gas per row.** Design D is the shipped design with the
`purchaseAmounts` array restored: 14,871 against 14,188 per row at 200 rows under via-IR, or 683 —
of which 201 is calldata. It is priced separately because it is a separate decision, taken in Gate 1.

**Two payers, not one.** The tick is paid by the protocol, every day, for the life of every schedule.
Create and delete are paid once, by the user who opens a schedule. This item makes the first cheaper
by 20% and the second dearer by about 23,500 gas, and those two figures are **not** netted into a
break-even here: they come out of different pockets, and a break-even in purchases would imply the
protocol's saving repays the user's cost, which it does not.

**Scale, for the payer that matters daily.** Rootstock's block gas limit is 10,000,000 (measured at
block 9,210,661), so one tick fits about **560 rows under the pre-R64 design and about 700 under the
shipped one** — the operational headroom is the part of this that compounds, not the fraction of a
cent per row.

## Decision

**Gate 1 — the recommendation was to keep the `purchaseAmounts` staleness guard; the decision was to
drop it.** The recommendation weighed 412 gas per row against a named revert, and treated
"one stale row reverts the whole batch" as a liveness cost the bot already carries for
`SchedulePaused` and can filter the same way. What that under-weighted is that the array is data the
contract does not need at all — it debits with its own stored value either way — and that the failure
it prevents is a purchase at the amount the user themselves had just asked for. Dropping it is
recorded as invariant 9 in `AGENTS.md` so it is not re-added by the next reader who notices the
schedule could change mid-flight. The NatSpec correction that this PR shipped regardless is now moot
in its original form and has been rewritten around what `Batch` actually carries.

**Gate 2 — the keying changes, and the schedule is now addressed by `(token, scheduleId)`.** The
measurement PR recommended keeping the pre-R64 nested design; the decision went the other way, on the
ground that the hot path is paid every day for years and this was the last moment it could be changed.
The measurement's own case against was about timing and blast radius, never about gas — and those are
the costs this change actually pays:

- Eight external signatures change, and five consumer repos with them. The swapper bot and the front
  end are both rewritten against a new addressing model.
- `purchaseAmount` narrows from `uint128` to `uint96` (~7.9e10 tokens at 18 decimals). Keeping
  `uint128` splits a purchase's two writes across two slots and gives back more than the change wins.
- Enumeration duplicates: create and delete each write two structures, and delete gains a linear scan
  bounded by the max-schedules-per-token setting.
- It is a storage redesign landing after the relaunch review stack was audited against the previous
  one, with no round left to audit it in.

Three implementations were written before one shipped, and the sequence is the useful part of this
record. The first was flat-by-id with the owner *and* the token stored (design C): correct, but three
slots, and every path that touched a schedule had to check the owner, so one omission would have been
another account's funds. The second put the owner into the key (`[scheduleId][user]`), which deleted
that hazard structurally and got back to two slots — but it forced the swapper to send an owner
address for every row, which is 20 bytes per row on the path the protocol pays for daily. The third,
which ships, puts the **stablecoin** in the key instead: a row goes back to a bare `uint64`, the
token check becomes structural in the same motion, and the owner becomes a field checked in exactly
one place. Measured at 200 rows under via-IR, that is 14,188 gas per row against 14,606 for
owner-in-key and 17,746 for pre-R64.

The ownership check is the price, and it is worth stating plainly rather than explaining away: a
stored owner can be forgotten, where a key cannot. What makes it acceptable is that it exists once,
in `_callersSchedule`, that every user-facing mutator reaches a schedule through it, and that the
purchase path — the only path that touches a schedule on somebody else's behalf — takes the owner
from storage and so has no check to forget. Invariant 8 in `AGENTS.md` states that, and states the
one grep that verifies it.

Invariant 7 in `AGENTS.md` — the public `scheduleId` is the creation nonce, never array state — is
unchanged either way, and still holds: ids still come from a strictly increasing counter, and the
per-owner id list still swap-pops, which is exactly the hazard that invariant exists to name.

---

## Implementation

The measurement PR priced two designs and recommended keeping the nested one. The decision went the
other way, and a review of the first implementation then found a better design still, which is what
shipped. Both steps are recorded here, because the second one is the more instructive.

### What shipped

`mapping(address token => mapping(uint64 scheduleId => DcaSchedule))`, a batch row of one `uint64`,
and no per-row buyer or amount.

**The stored schedule is two slots**, because neither half of the key is repeated in it:

| slot | fields | bytes used |
|---|---|---|
| 0 | `tokenBalance` u128 · `lastPurchaseTimestamp` u48 · `paused` · `purchasePeriod` u32 · `routeIndex` u32 | 31 of 32 |
| 1 | `user` · `purchaseAmount` u96 | 32 of 32 |

Slot 0 is every field a purchase reads or writes, so a purchase is still one `SSTORE`. Buying that
costs `purchaseAmount` 32 bits of width — `uint96` caps one purchase at ~7.9e10 tokens at 18 decimals,
while `tokenBalance` keeps `uint128` — because at `uint128` the pair no longer fits beside an address
and the two writes split across slots, which costs more than the narrower field saves.

**There is one schedule type, not two.** The earlier implementation carried a storage-only
`StoredSchedule` plus an ABI `DcaSchedule` that added the id back on the way out. That is gone:
`getDcaSchedules` returns the ids in a parallel array alongside the structs, so nothing has to be
duplicated into the value to make a read actionable, and there is no pair of near-identical types to
keep in sync.

### Why the stablecoin is in the key, and the owner is a field

Three designs fit a schedule in two slots, and each pays for it somewhere different. Only one of the
two halves of a schedule's identity — its owner and its stablecoin — can go in the key beside the id
without a third slot, so the choice is which one:

- **owner in the key** (`[scheduleId][user]`, the previous implementation): ownership is structural
  and unforgeable, but the swapper must then send the owner's address for every row, because the
  purchase path is the one place a schedule is reached on somebody else's behalf. That is 20 bytes
  per row, forever, on the path the protocol pays for daily. Measured as design I, and as design G
  with both in the key: **+415 and +418 gas per row** against what shipped, at 200 rows under via-IR.
- **stablecoin in the key** (what shipped): the token check is structural instead — a row naming a
  schedule of a different stablecoin addresses empty storage and is refused, rather than being
  debited by a handler that never held its funds — and a row is a bare `uint64`. Ownership becomes a
  stored field, checked in exactly one place.
- **neither in the key**, with the token replaced by a compact `uint32 routeId` minted by
  `OperationsAdmin` (design F): the same hot path within noise (**−233 gas per row**), at the cost of
  a second identifier alongside `routeIndex` and a change to the governance contract. Rejected on
  those grounds, not on gas.

The ownership check the shipped design pays for lives in `_callersSchedule(token, scheduleId)` and
nowhere else. Every user-facing mutator reaches a schedule through it; the purchase path needs no
check at all, because it reads the buyer from the schedule rather than taking one from the caller.
That is what invariant 8 in `AGENTS.md` now says, and the reviewer's obligation it names is a single
grep: no mutator may read `s_dcaSchedules` directly.

**Key order was measured, not assumed.** `[token][scheduleId]` and `[scheduleId][token]` are the same
storage and the same work; the token being outermost makes its hash loop-invariant, and whether the
compiler hoists it decides the sign. On the shipped contract under via-IR, at 200 rows,
`[scheduleId][token]` measures 14,167 gas per row against 14,188 for `[token][scheduleId]` — the
token-first order costs **21 gas per row, 0.15%**. It ships anyway, because
`s_dcaSchedules[token][scheduleId]` says what the mapping is (for each stablecoin, the schedules that
spend it) while `s_dcaSchedules[scheduleId][token]` reads as an id with a second key bolted on, and
0.15% is not worth a storage declaration that misleads every future reader. An isolated two-contract
probe had the saving the other way round at ~17 gas per row; it did not survive contact with the full
contract, which is why the number quoted here is the in-situ one.

### Why a batch row carries no amount

`purchaseAmounts` was kept in the first implementation as a staleness guard: a row whose amount no
longer matched storage reverted rather than buying. Measured at ~450 gas per row, and what it bought
was turning one user's edit between the swapper's snapshot and the tick into a failed tick for every
other row in the batch — in order to refuse a purchase at the amount that user had just asked for. The
manager debits with its own stored value either way, so the array was never anything but a comparison.
It is gone; the manager reads what each row spends from its schedule. `minRbtcOut` still binds on the
rBTC the handler measures itself receiving, and a Uniswap route's oracle floor still scales with the
actual input, so nothing about slippage rested on it. The `routeIndex` comparison stays and is a
different thing: no setter can change a schedule's route, so it is an integrity check that the row
belongs to this batch's handler, not a guard against staleness.

### Surface

Eight external signatures take `(token, scheduleId)` where they used to take `(token, scheduleIndex,
scheduleId)` before R64 and a bare `scheduleId` in the first implementation: `depositToken`,
`withdrawToken`, `withdrawTokenAndInterest`, `deleteDcaSchedule`, `updatePurchaseAmount`,
`updatePurchasePeriod`, `setSchedulePaused`, `topUpFromInterest`. `getDcaSchedule(user, token, index)`
becomes `getDcaSchedule(token, scheduleId)`. `getDcaSchedules(user, token)` keeps its arguments but
now returns `(uint64[] scheduleIds, DcaSchedule[] schedules)`. `createDcaSchedule` is unchanged.
`Batch` becomes `{uint64[] scheduleIds; address token; uint256 routeIndex; uint256 minRbtcOut}`.
`DcaManager__ScheduleTokenMismatch` is deleted — the state it named is now unrepresentable — and
`DcaManager__NotScheduleOwner(token, scheduleId, owner)` is added. `InexistentSchedule`,
`SchedulePaused`, `ScheduleBalanceNotEnoughForPurchase` and `RouteIndexMismatch` all now name a
schedule as `(token, scheduleId)` rather than by owner. `IPurchaseRbtc.batchBuyRbtc` is untouched, as
**Out of scope** required.

### What it cost and bought

`batchBuyRbtc`, 200 rows, total per row including intrinsic calldata. Every alternative priced along
the way is kept in `test/gas/R64BatchGasBenchmark.t.sol` so the choice can be re-checked rather than
re-argued. B is the pre-R64 keying, reproduced as a prototype:

| | default | via-IR (ships) | vs shipped, via-IR |
|---|---|---|---|
| B — pre-R64 `[user][token][index]`, four arrays | 18,931 | 17,746 | +3,558 |
| C — flat by id, owner *and* token stored, three slots | 17,008 | 16,100 | +1,912 |
| I — `[user][token][id]`, both structural, buyers in the batch | 15,730 | 14,606 | +418 |
| G — `[id][user][token]`, both structural, buyers in the batch | 15,687 | 14,603 | +415 |
| H — G's key, row packed as one word `(id << 160) | buyer` | 15,069 | 14,219 | +31 |
| **A — shipped: `[token][id]`, owner stored and checked** | **14,231** | **14,188** | — |
| E — the same design keyed `[id][token]` | 14,910 | 13,951 | −237 |
| F — flat by id, `uint32 routeId` in place of the token | 14,901 | 13,955 | −233 |

E and F sit a fifth of a percent below the shipped design and were rejected on what they cost outside
the gas table: E's mapping reads as an id with a useless second key, and F needs a second route
identifier minted inside `OperationsAdmin`. The E row measured here is a prototype, which the compiler
optimises more aggressively than the full contract; the like-for-like key-order comparison on the
shipped contract is the 21 gas per row above, not this 237.

Cold paths, per schedule, paid by the user:

| | create (default) | delete (default) | create (via-IR) | delete (via-IR) |
|---|---|---|---|---|
| B — pre-R64 | 99,928 | 10,924 | 98,125 | 10,567 |
| **A — shipped** | **122,629** | **11,789** | **121,636** | **11,860** |

Create costs the user about 23,500 gas more than the pre-R64 design and delete about 1,200 more for
the id-list scan; both are paid once per schedule, by the user, while the 3,558 gas per row the tick
saves is paid every day, by the protocol. The two are different bills and are not netted here.

### What did not change

Ids are still the creation nonce from a strictly increasing counter, still start at 1, and are still
retired by deletion rather than reused (invariant 7). Every external function that writes
`s_dcaSchedules` still carries `nonReentrant` as its first modifier, with the two `onlySwapper`
purchase paths the same documented exception (invariant 6). Events keep their signatures, field
meanings and indexed fields. A zero token is still rejected at create even if governance assigned that
pair a handler — no longer because it is an existence sentinel, but because a schedule's stablecoin is
fixed for life and "a schedule's token is a token" is worth one comparison on a cold path.
