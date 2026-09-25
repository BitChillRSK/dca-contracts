# Rootstock gas audit of `src/` (2026-09-23)

This is a one-time review of every storage-, call-, and approval-shaped gas decision in `src/`,
re-priced on Rootstock's schedule ([`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md)) instead
of the Ethereum/Cancun schedule Foundry reports. It asks two questions of each decision:

1. Did an optimization shipped on Foundry evidence actually do nothing, or cost gas, on Rootstock?
2. Did Foundry hide a cost that Rootstock charges in full?

Audited at `8d07bf9` (R78 / [#139](https://github.com/BitChillRSK/dca-contracts/pull/139) head).

## Method

Foundry could not be installed in the audit environment, so every figure here comes from a separate
harness that the implementing PRs must re-measure with Foundry:

- The real `OperationsAdmin` and `DcaManager` (and `IdleDocHandlerMoc` for the fee setter), plus
  `test/gas/StubPurchaseHandler.sol`, compiled with solc 0.8.36 (npm `solc`), `cancun`, optimizer 200.
  Both the default profile (legacy codegen) and the deploy profile (`via_ir`) were built.
- The contracts ran in `@ethereumjs/vm` on the Cancun hardfork, the same schedule Foundry/revm uses.
  "Cancun exec" in the specs is that VM's execution gas. The VM keeps EIP-2929 warm sets across calls,
  as a Foundry test without `vm.cool` does, so Cancun absolutes are warm-biased and the Foundry
  re-measurement will differ. Rootstock storage figures come from traced opcodes and are unaffected.
  Rootstock figures derived for removed calls assume each removed call and read was warm on Cancun.
  That holds on-chain too, because every removed call repeats one made earlier in the same transaction.
- Every `SLOAD`, `SSTORE`, `TLOAD`, and `TSTORE` was traced with the slot's value before the write,
  then priced with rskj's constants (`SLOAD` 200; `SET` 20,000 / `RESET` 5,000 / `CLEAR` 5,000 +
  `REFUND` 15,000; `TLOAD`/`TSTORE` 100). That total is "RSK storage".
- rskj facts not already in the schedule were read from rskj `master` on 2026-09-23: `GasCost.java`,
  `Transaction.java` (calldata), `OpCode.java`, `VM.java` (`doTLOAD`/`doTSTORE`), and
  `reference.conf` / `config/main.conf` (activation heights).

The stub handler moves no tokens, so handler-side storage (`s_idleBalances`, `s_shares`,
`s_usersAccumulatedRbtc`) was reasoned from source, not traced. R79 covered that side and was closed
without implementation (about 1% of a batch; see [R79](./R79-coalesce-repeated-buyer-writes.md)).

## Findings → specs

| # | Finding | Who pays | Foundry shows | Rootstock | Spec |
|---|---|---|---:|---:|---|
| 1 | Purchase row writes `DcaSchedule` slot 0 twice (`tokenBalance`, then `cadenceAnchor`) | protocol, every row | −215 / row | **−5,200 / row** | [R81](./R81-one-write-per-packed-slot.md) |
| 2 | Storage `ReentrancyGuard` does two `RESET`s per guarded call | user, 12 entry points | −2,800 / call | **−9,900 / call** | [R82](./R82-transient-reentrancy-guard.md) |
| 3 | `createDcaSchedule` struct literal writes slot 0 five times | user, per create | −1,052 | **−15,600** (deploy) | [R81](./R81-one-write-per-packed-slot.md) |
| 4 | Exact-amount approvals go 0 → X → 0 every use (router per Dex batch; lending spender per deposit) | protocol / user | −23,480 exec, mostly refunded | **~−10,400 / use** (USDRIF) or **~−5,400** (DOC, USDT0), after a one-time ~20,000 at deploy (break-even ≈ 2–4 uses) | [R83](./R83-standing-spender-approvals.md) (answered: standing, both sites) |
| 5 | `setFeeRateParams` writes the packed fee word up to four times | owner | small | up to −15,000 | [R81](./R81-one-write-per-packed-slot.md) measured, declined |
| 6 | `withdrawTokenAndInterest` resolves the same handler twice | user, per call | −1,194 | ≈ **−1,900** (deploy) | [R84](./R84-no-repeated-registry-reads.md) |
| 7 | Deposit routing, `topUpFromInterest`, and `withdrawAllAccumulatedInterest` each make two registry calls for one route | user, per call / per pair | −341 to −351 | ≈ −940 to −950 (deploy) | [R84](./R84-no-repeated-registry-reads.md) |

Row 6 and the interest paths in row 7 were raised in review of #140, after the first pass had
checked only deposit routing for repeated registry calls. With R84, no user path reads the same
registry fact for the same route twice. The remaining multi-call paths are listed under **Closed
without a spec**.

What links 1, 3, and 5: the compiler writes a packed field as its own `SSTORE` unless the writes are
adjacent with nothing that can revert, log, or call between them. Cancun prices the extra writes at
~100 each; Rootstock prices them at 5,000 each. See
[`ROOTSTOCK-GAS-SCHEDULE.md` § Packed-field writes](./ROOTSTOCK-GAS-SCHEDULE.md#packed-field-writes).

## Already tracked

- **R77 accumulated-rBTC sentinel.** This is the only shipped optimization that is a net system cost
  on Rootstock. Storage is exactly neutral (`SET − REFUND = RESET`), and the always-on encode overhead
  (+298 / +938 Foundry, compute, which transfers) is a real net cost. The human accepted it on
  2026-09-18 as a cost transfer from swapper to user. No change.
- **R79** (repeated-buyer write coalescing) and **R80** (cadence event) were already priced on
  Rootstock in R78's deferred record. R79 was later closed without implementation; see
  [its record](./R79-coalesce-repeated-buyer-writes.md).

## Confirmed sound on Rootstock

- **Schedule packing (R18 / R50 / R64), `uint64[]` id packing, `TokenRoute` handler+pause packing, and
  the R78 fee-word packing.** Each still saves `SLOAD`s (200 each) and avoids new-slot `SET`s. The
  saving is smaller than Foundry's cold-access figures, but it has the same sign.
- **`_setUserShares` taking the already-loaded `previousShares`.** Avoiding a re-read is worth more on
  Rootstock (200) than on Cancun (100 warm).
- **R78 compute changes (flat loop, stack scalars, dropped equality test).** These are compute only, so
  they transfer 1:1.
- **R64 calldata work (a batch row is one `uint64` id).** Rootstock adopted EIP-2028 (RSKIP-400,
  Arrowhead 6.0.0, block 6,223,700), so calldata is 16 / 4 gas per non-zero / zero byte, the same as
  Ethereum.
- **Logs, memory, and arithmetic.** Identical schedules.

## Closed without a spec

- **`deleteDcaSchedule` swap-and-pop writes the id-array word twice** when the moved id and the popped
  slot share a word (four ids per word). That is +5,000 user gas on a rare call. Assigning then
  popping, in either order, is two read-modify-writes of the same word, and merging them needs
  assembly. Accepted.
- **`setFeeRateParams` writes the fee word up to four times.** Measured in R81 (−16,200 / −15,600
  Rootstock when all four change). Declined: owner-only and at most yearly; keep the per-field
  if/write/emit shape. R81 ships purchase and create only.
- **Four `SLOAD`s of schedule slot 0 per purchase row** (about 600 gas of re-reads at 200 each), counted
  before R81. The merged write removes one of those reads on the default profile and two under deploy;
  the rest are field reads the optimizer does not CSE across the checks. Not worth a memory copy of the
  whole struct.
- **`batchBuyRbtc` calls `OperationsAdmin` twice per batch**: `isSwapper` in `onlySwapper`, then
  `getTokenHandler`. By analogy with finding 7, that is roughly 950 protocol gas per batch; this was
  not measured. It is per batch, not per row (`batchBuyRbtcAcrossHandlers` checks the swapper once for
  all batches). Merging it would need a view that couples authorization with route resolution. Closed.
- **After R84, `withdrawTokenAndInterest` still makes two registry calls**, one for the handler and
  one for the route class. Those are two distinct facts. Folding the class into `_withdrawToken`
  would add a read to plain `withdrawToken`, and it is unmeasured. Closed (R84 out of scope).
- **`getInterestAccrued` makes two registry calls.** It is a view, reached through `eth_call`, so it
  costs no transaction gas. Closed.
- **`withdrawAllAccumulatedRbtc` pre-checks each pair's balance before withdrawing.** That is an extra
  700-gas call per pair, but it is how the batch skips instead of reverting on an empty pair. It is
  behavior, not an optimization.

## Deferred candidates (2026-09-25)

On 2026-09-25 the purchase path was reviewed again at `068a380` (R79 head). The model behind it came
from the 98 live swapper batches of the old contracts:
- **The live fit.** Each batch cost about 740k fixed plus about 40k per row; the median batch had 7 rows.
- **Where the fixed part goes.** Most of it is the venue: the MoC redeem, the Tropykus redeem.
- **A relaunch row, counted from source.** About 24k: three `RESET`s, about 1.2k of reads,
  3.4k–5.8k of events, and about 3k of compute.

The review produced seven candidates:
- **One shipped.** `calldata` for the handler's batch arrays became
  [R86](./R86-calldata-array-parameters.md).
- **Six deferred.** The human deferred the other six rather than closing them. They sit here so a
  later pass does not re-derive them. [R87](./R87-deferred-gas-candidates.md) measures each one and
  asks the human for a verdict.

Figures are Rootstock gas, estimated from source; none of the six has been measured.

- **Remove `IdleErc20Handler.s_idleBalances`.** This is the only candidate above about 2% of a batch.
  - **Saving:**
    - Protocol: about 5.3k per idle purchase row (one `RESET` plus its read), about 5–6% of a 10-row idle
      MoC batch, and more on Dex.
    - Users: about 5.2k per idle deposit or withdrawal, and about 20k on a first deposit.
  - **Why it waits:**
    - It can never disagree with `DcaManager`: deposits, purchases and withdrawals move both by the
      same amount, and route bindings are add-only. So the saving costs no accuracy.
    - What it does cost is the one limit an idle handler enforces on its own. If `DcaManager` ever
      overstated a schedule's balance, the ledger still stops that user at their own deposits.
      Without it, an idle handler spends whatever it is told from the pooled balance, in contracts
      with no upgrade and no pause.
    - It also gives every handler the same rule, "no user takes out more than they put in". Lending
      handlers must keep `s_shares` anyway, so an auditor can check that rule handler by handler.
  - **Money:** about $0.13 per 10-row batch, or about $20 a year across three weekly idle routes.
- **Trim purchase-row event fields.**
  - **Saving:** about 2.4k per lending row, about 2%:
    - per-row `TokenLending__UserSharesUpdated` in lending batches, about 1.7k;
    - `PurchaseRbtc__RbtcBought`'s `tokenSpent` topic and `amountSpent` word, about 0.7k.
  - **Why it waits:** each field can be derived, but consumers read each one. That is the argument
    [R80](./R80-remove-cadence-anchor-event.md) used to keep `TokenBalanceUpdated`. Every event change
    is a five-repo cutover, so it can only land before relaunch deploy.
- **Keep fees in the handler and sweep them**, instead of a `safeTransfer` every batch.
  - **Saving:** about 10k per batch, about 1%.
  - **Why it waits:**
    - It adds a fee counter, a sweep entry point, and a custody rule that separates fee balance from
      users' pooled idle balance.
    - A lending-only version needs no counter, but then idle and lending handlers pay fees differently.
- **Drop `FeeHandler__FeeTransferred`.** It repeats the ERC-20 `Transfer` to the collector.
  - **Saving:** about 1.8k per batch (`LOG3` with one data word).
  - **Why it waits:** the edit is small, but removing an event is a monitoring and indexer cutover like
    R80's, for about 0.2% of a batch.
- **Reuse the lending redeem's post-balance as the purchase's pre-balance.**
  - **Saving:** one stablecoin `balanceOf`, about 1.2k per lending batch.
  - **Why it waits:**
    - Today, invariant 11's measurement in `LendingErc20Handler` and invariant 12's in `PurchaseRbtc`
      are each self-contained.
    - Sharing the reading ties them together across two layers. A later change to either check could
      then quietly weaken the other.
- **Raise `optimizer_runs` above 200.**
  - **Saving:** compute only. Unmeasured; probably under 0.1% of a batch.
  - **Why it waits:**
    - It changes every deployed byte and re-baselines every recorded Foundry figure.
    - It grows runtime size and deploy cost.
    - [#104](https://github.com/BitChillRSK/dca-contracts/pull/104) settled 200.
  - **When it is measured, also check whether a higher value makes the R81 helpers unnecessary.**
    `_storeNewSchedule` and `_storePurchaseProgress` exist only to make the compiler store each packed
    schedule slot once. To test that:
    1. Put their assignments back inline in `createDcaSchedule` and `_rBtcPurchaseChecksEffects`.
    2. Count writes per slot with `test/gas/R81PackedSlotWritesGas.t.sol` on both profiles.
  - **The opposite can also happen.** `_storePurchaseProgress` merges its two writes only in its own
    frame. If a higher value lets the inliner fold it into the caller, the writes split again, at 5,000
    per row on Rootstock. The same R81 tests catch that, so run them at any new setting even if the
    helpers stay.

## Documentation corrections

- The "~2,300 gas ≈ 1.4 cents" figure for the reentrancy guard is its **Cancun** net cost. On Rootstock
  the guard costs about 10,200 per guarded call. `AGENTS.md` invariant 6 is corrected in this PR.
  Historical records stay as written, per the measurement-basis rule in `README.md`:
  - R6 and `IMPLEMENTATION_ORDER.md` PR 6 quote ~2,300 as the guard's cost when deciding to keep it.
    The decision stands; the real cost only strengthens R82.
  - R19 uses ~2,300 as a yardstick for a purchase-path cost it accepted as temporary. R18 then removed
    that cost, so there is nothing to redo.
  - R55 and R69 use "~2,300 gas ≈ 1.4¢" only as a gas-to-cents conversion ratio. That ratio does not
    depend on what the guard costs, so it is unaffected.
- `ROOTSTOCK-GAS-SCHEDULE.md` covered storage only. This PR adds account access, transient storage,
  calldata, and the packed-field-write rule.
