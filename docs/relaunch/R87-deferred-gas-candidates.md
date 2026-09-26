# R87 — consider the deferred gas candidates

Status: **decided 2026-09-26; implementation pending** · Assigned: yes · Optional/further-review: no

## Objective

Decide, one by one, whether to carry out any of the six gas candidates the 2026-09-25 purchase-path
review deferred. This PR records the decisions; a follow-up R87 implementation PR ships the approved
candidates after their proof and test gates pass.

## Verdicts (2026-09-26)

Measured on a throwaway Foundry harness (not shipped) under the deploy profile at `c305e8d` (R86 head).
It ran one 10-row batch per lane (MoC idle, Sovryn and LayerBank DOC, Dex idle and LayerBank USDRIF),
counted reads and writes per slot with `vm.startStateDiffRecording`, and converted to Rootstock gas
with [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). A 10-row batch is about 1.0M Rootstock
gas, about $2.50 at 0.03 gwei.

These figures were sufficient for the product verdicts, but they are not reproducible regression pins:
the throwaway harness was not retained and the default profile was not measured. The implementation PR
must retain the final gas tests or an exact harness commit and commands, measure both profiles, and
re-record the Rootstock conversion before it cites the savings as final.

The rule applied: a change that removes redundant state, code, or a compiler check may be accepted
regardless of percentage when its equivalence or numeric bound is explicit and tested. A change that
adds state, branches, ABI surface, cross-layer coupling, or manually maintained layout must clear about
1% **and** a meaningful dollar amount. These contracts are meant to be final, so nothing rejected here
is revisited later.

| Candidate | Measured Rootstock saving | Verdict | Why |
|---|---|---|---|
| Remove `IdleErc20Handler.s_idleBalances` | ≈5.75k per idle row (one `SLOAD`, one `RESET`), ≈5.7% of a 10-row idle batch; users ≈5.5k per idle deposit or withdrawal, ≈20k on a first deposit | **Remove, subject to the proof gate below** | Deletes correlated shadow state. The ledger is updated from the same DcaManager-supplied user and amount as the schedule liability; it is not an independent source of truth. Its residual defense-in-depth is accepted only after the stronger per-user, aggregate, enumeration, and cross-user invariants below pass. |
| Drop `FeeHandler__FeeTransferred` | 1,804 per batch | **Drop** | Deletes duplicate hot-path telemetry. The stablecoin's same-transaction ERC-20 `Transfer` from the handler to the current fee collector contains the same token, sender, recipient, and amount. Monitoring must consume that event instead. |
| Trim purchase-row event fields | `TokenLending__UserSharesUpdated` 1,742 per lending row; `RbtcBought`'s `tokenSpent` + `amountSpent` ≈650 per row | Keep | Events stay rich. |
| Keep fees in the handler and sweep them | 14.0k per lending batch (no counter); 8.5k per idle batch (counter) | Reject | ≈1–1.4%, about $3 a year even with a yearly sweep. Adds an entry point, a counter, a custody rule, and a "never pay out `balanceOf(this)`" rule for lending code. |
| Reuse the redeem's post-balance as the purchase's pre-balance | 1,550 per lending batch | Reject | ≈0.15%. Changes the `_batchRetrieveStablecoin` signature, gives invariant 12 two code paths (idle has no redeem measurement), and couples invariants 11 and 12 across layers. |
| Raise `optimizer_runs` | 10,000: −2.8k to −3.5k per batch; 1,000,000: −4.1k to −5.4k per batch | Keep 200 | Deploy gas +3.3M / +6M, break-even 11–14 years. `DcaManager` grows 11,267 → 16,179 bytes; `LayerBankErc20HandlerDex` headroom shrinks 11,198 → 6,154 bytes. Writes per slot identical and the R81 tests pass at every value, so the R81 helpers stay. |
| Assembly in the purchase path (added by the human) | `PurchaseRbtc` row loop ≈720 per row (≈0.7%); whole path estimated ≈1.5–2k per row | Reject | Compute is ≈4.2k of a ≈24k row, so even deleting all of it caps at ≈4%. It would override invariant 5, copy the rBTC encoding out of its helpers (invariant 13), and hand-maintain event and storage layout the compiler checks today. |
| `unchecked` credit add in `_creditRbtc` (added by the human) | ≈45 per row | **Add** | The check is redundant: credits are shares of rBTC the handler measured receiving, total claims cannot exceed handler cash, and the stored `claimable + 1` value is bounded by Rootstock's native supply (about 2⁸⁵ wei), far below `uint256`. The block stays inside `_creditRbtc`, so invariant 13 holds. |

### Idle-ledger proof and accepted residual risk

For an idle handler `H`, define a user's liability as the sum of `tokenBalance` across every live
schedule owned by that user and routed to `H`. The only five liability-changing transitions are:

| Transition | Handler cash | Schedule liability |
|---|---:|---:|
| Create | `+deposit` | `+deposit` |
| Deposit | `+deposit` | `+deposit` |
| Purchase | `-gross` | `-gross` |
| Withdraw | `-requested` | `-requested` |
| Delete | `-remaining` | `-remaining` |

Each transition is atomic, so a failed handler call rolls the schedule write back. Schedules are private
and mutated through a narrow surface; user exits use the single ownership check; purchases take buyer and
amount from the stored schedule; route integrity is checked; handler assignment and each schedule's route
are immutable; one handler address can serve only one token/route; and handler funding calls accept only
the immutable DcaManager. Interest top-up cannot target an idle route. Those constraints make the handler
ledger a correlated shadow of DcaManager accounting, rather than an independent reconciliation source.

The ledger does retain one defense-in-depth property: it can reject or clamp a DcaManager request above
the user's recorded handler credit. That containment is incomplete. On withdrawal or deletion, the idle
handler can clamp the payout after DcaManager has already deducted the full requested schedule liability,
and DcaManager ignores the returned amount; a mismatch can therefore underpay the user and destroy the
remaining claim. The removal deliberately accepts the residual risk of an undiscovered DcaManager
over-debit bug because the duplicate ledger is driven by the same user and amount and does not safely
reconcile such a mismatch.

Implementation is gated on stateful tests that prove all of the following:

1. A test-only per-user ghost liability equals the sum of that user's live idle schedule balances.
2. Handler stablecoin cash is at least the sum of all live idle liabilities; absent unsolicited token
   transfers, the values are equal.
3. Enumeration scans creation ids `1..scheduleNonce`, proves every live schedule appears exactly once,
   and proves its recorded owner is correct; it must not trust only the per-user enumeration arrays.
4. Any transition for one user leaves every other user's liability unchanged.
5. Coverage guards prove successful create, deposit, purchase, withdraw, and delete transitions all ran.

The strongest implementation sequence first runs the ghost model against the pre-removal contract and
asserts `s_idleBalances == ghost == schedule sum`; after removing the ledger, the final suite retains the
ghost and schedule assertions.

### Fee-event replacement

`SafeERC20.safeTransfer` does not emit an event itself; the listed stablecoin emits the standard ERC-20
`Transfer`. For each successful batch transaction, monitoring filters the stablecoin's `Transfer` by
`from = handler`, `to = current fee collector`, and `value = aggregate fee`. Handler addresses make the
signal unambiguous across routes. This decision relies on every listed stablecoin continuing to emit the
standard event; a token that does not is not compatible with this monitoring replacement.

Approved for follow-up implementation: removing the idle ledger, getter, clamp event, and related errors
after the proof gate passes; dropping `FeeHandler__FeeTransferred`; and adding the `unchecked` credit.
Each candidate ships in its own commit, with consumer issues for the ABI and event removals.

## Background

The six candidates, with their estimated savings and the reasons they were deferred, are recorded in
[`ROOTSTOCK-GAS-AUDIT.md` § Deferred candidates](./ROOTSTOCK-GAS-AUDIT.md#deferred-candidates-2026-09-25).
Read that section first; this spec does not repeat it.

Every figure there is an estimate from source. None has been measured. The human wants each candidate
judged on a measured saving against what it costs in complexity, safety margin or consumer work. The
yardstick is the one R79 and R84 applied: a saving of about 1% does not justify permanent complexity in
immutable contracts.

Everything the human approves must land before relaunch deploy. The contracts are immutable, so
nothing here can ship later.

## Open product decisions

The human decides each of these after seeing its measurement. Ask them all together, once the
measurements are done:

1. **Remove `IdleErc20Handler.s_idleBalances`?** This gives up the one per-user limit an idle handler
   enforces on its own.
2. **Trim purchase-row event fields?** That is per-row `TokenLending__UserSharesUpdated` in lending
   batches, and `PurchaseRbtc__RbtcBought`'s `tokenSpent` topic and `amountSpent` word. Every event
   change is a five-repo cutover.
3. **Keep fees in the handler and sweep them?** This adds a fee counter, a sweep entry point and a
   custody rule. A lending-only version would make idle and lending handlers pay fees differently.
4. **Drop `FeeHandler__FeeTransferred`?** This is an event removal, so it is a consumer cutover.
5. **Reuse the lending redeem's post-balance as the purchase's pre-balance?** This couples the
   measurements behind invariants 11 and 12.
6. **Change `optimizer_runs` from 200, and if so to what?** If a higher value lets the compiler store
   each packed slot once, also decide whether to inline the R81 helpers.

## Scope

- [x] **Produce decision figures before asking.**
  - The verdict run used Foundry's deploy profile against the R86 head.
  - Convert every figure to Rootstock gas with
    [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). Count writes per slot wherever storage
    changes, as `AGENTS.md` requires.
  - The follow-up implementation must repeat the final measurements on both profiles and retain the
    harness or its commit and commands.
- [x] **For `optimizer_runs`**, measure at least one purchase batch, deployed size and deploy gas at
  200 against one or two higher values.
  - At each value, check `test/gas/R81PackedSlotWritesGas.t.sol` with the helpers as they are.
    - Why: a higher value may inline `_storePurchaseProgress` into its caller and split the merged
      writes again.
  - Then inline `_storeNewSchedule` and `_storePurchaseProgress` back into `createDcaSchedule` and
    `_rBtcPurchaseChecksEffects`, and run the same tests. That shows whether the helpers are still
    needed.
- [x] **Present one table to the human**, listing each candidate's:
  - measured Rootstock saving, per row or per batch;
  - share of a typical batch;
  - cost;
  - recommendation.
- [x] **Record the product verdicts in a docs-only PR.**
- [ ] **Implement the approved candidates in a follow-up R87 PR:**
  - Branch from this verdict PR's head after it merges or from the latest open relaunch PR's head.
  - Implement each approved candidate in its own commit, with the proof and tests above.
  - Retain reproducible gas evidence and measure both profiles.
  - Open consumer issues for every removed event, getter, or error (`AGENTS.md` **Consumer follow-up**).

## Out of scope

- [ ] New candidates the deferred record does not list. Report them to the human; do not implement
  them.
- [ ] Anything already closed: R79, the slot-0 re-reads, the two OperationsAdmin calls per batch,
  and `TokenBalanceUpdated`.

## Files likely touched

The files depend on which candidates are approved, so only the measurement harnesses are known in
advance:

- idle ledger: `src/idle/IdleErc20Handler.sol`, `src/idle/IIdleErc20Handler.sol`
- event fields: `src/interfaces/IPurchaseRbtc.sol`, `src/PurchaseRbtc.sol`,
  `src/interfaces/ITokenLending.sol`, `src/LendingErc20Handler.sol`
- fee sweep and `FeeTransferred`: `src/FeeHandler.sol`, `src/interfaces/IFeeHandler.sol`,
  `src/PurchaseRbtc.sol`
- balance reuse: `src/LendingErc20Handler.sol`, `src/StablecoinSource.sol`, `src/PurchaseRbtc.sol`
- optimizer: `foundry.toml`, `src/DcaManager.sol`
- `docs/relaunch/ROOTSTOCK-GAS-AUDIT.md`, `docs/relaunch/README.md`,
  `docs/relaunch/IMPLEMENTATION_ORDER.md`
- the matching tests under `test/`, plus new ones under `test/gas/`

## Required tests

- **This verdict PR:** docs only; no build required.
- **The implementation PR:** the gate for its tier under **Scale the gate to the change** in `AGENTS.md`. For
  any `src/` or `foundry.toml` change, that means `make check`, `make check-deploy`,
  `make fork-sovryn` and `make fork-tropykus`.
  - For `optimizer_runs`, also `make fork-dex-path`. Re-record every gas figure the PR cites.

## Success criteria

- [x] Every candidate has a Rootstock decision figure and a verdict from the human.
- [x] The verdict PR records the accepted safety tradeoffs and implementation gates.
- [ ] The follow-up PR carries only the approved candidates and updates the gas audit to match what it
  ships.

## Reviewer checklist

- [ ] Only human-approved candidates are implemented.
- [ ] Protocol invariants in `AGENTS.md` still hold, unless an approved candidate changes one and says so.
- [ ] Final Rootstock figures are reproducible and show how they were derived on both profiles.
- [ ] Consumer issues are opened for every removed event, getter, or error.

## ABI / deploy / cutover impact

It depends on what is approved:
- **Removing the idle ledger** removes the `getUsersIdleTokenBalance` getter.
- **The event candidates** change events, so they are cutovers.
- **The fee sweep** adds an entry point.
- **Balance reuse and `optimizer_runs`** change no ABI.
