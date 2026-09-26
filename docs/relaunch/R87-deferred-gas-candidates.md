# R87 — consider the deferred gas candidates

Status: **decided 2026-09-26; implementation pending** · Assigned: yes · Optional/further-review: no

## Objective

Decide, one by one, whether to carry out any of the six gas candidates the 2026-09-25 purchase-path
review deferred. Any candidate the human approves ships in this item's PR.

**If the human approves none, R87 opens no branch and no PR.** The deferred record in the gas audit
stays as it is, and the chat ends with the verdicts reported to the human.

## Verdicts (2026-09-26)

Measured on a throwaway Foundry harness (not shipped) under the deploy profile at `c305e8d` (R86 head).
It ran one 10-row batch per lane (MoC idle, Sovryn and LayerBank DOC, Dex idle and LayerBank USDRIF),
counted reads and writes per slot with `vm.startStateDiffRecording`, and converted to Rootstock gas
with [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). A 10-row batch is about 1.0M Rootstock
gas, about $2.50 at 0.03 gwei.

The rule applied: a saving that deletes code is taken even when small. A saving that adds code must
clear about 1% **and** a meaningful dollar amount. These contracts are meant to be final, so nothing
rejected here is revisited later.

| Candidate | Measured Rootstock saving | Verdict | Why |
|---|---|---|---|
| Remove `IdleErc20Handler.s_idleBalances` | ≈5.75k per idle row (one `SLOAD`, one `RESET`), ≈5.7% of a 10-row idle batch; users ≈5.5k per idle deposit or withdrawal, ≈20k on a first deposit | **Remove** | Deletes code. The ledger always equals the sum of that user's idle schedule balances: every `tokenBalance` writer moves it by the same amount, and route bindings are write-once and add-only. So its check can never fire. Ship with an invariant test: idle handler stablecoin balance ≥ Σ idle schedule balances. |
| Drop `FeeHandler__FeeTransferred` | 1,804 per batch | **Drop** | Deletes code. The same-call ERC-20 `Transfer` to the collector carries the same data, and BitChill pays for it every batch. The consumer cutover is already under way. |
| Trim purchase-row event fields | `TokenLending__UserSharesUpdated` 1,742 per lending row; `RbtcBought`'s `tokenSpent` + `amountSpent` ≈650 per row | Keep | Events stay rich. |
| Keep fees in the handler and sweep them | 14.0k per lending batch (no counter); 8.5k per idle batch (counter) | Reject | ≈1–1.4%, about $3 a year even with a yearly sweep. Adds an entry point, a counter, a custody rule, and a "never pay out `balanceOf(this)`" rule for lending code. |
| Reuse the redeem's post-balance as the purchase's pre-balance | 1,550 per lending batch | Reject | ≈0.15%. Changes the `_batchRetrieveStablecoin` signature, gives invariant 12 two code paths (idle has no redeem measurement), and couples invariants 11 and 12 across layers. |
| Raise `optimizer_runs` | 10,000: −2.8k to −3.5k per batch; 1,000,000: −4.1k to −5.4k per batch | Keep 200 | Deploy gas +3.3M / +6M, break-even 11–14 years. `DcaManager` grows 11,267 → 16,179 bytes; `LayerBankErc20HandlerDex` headroom shrinks 11,198 → 6,154 bytes. Writes per slot identical and the R81 tests pass at every value, so the R81 helpers stay. |
| Assembly in the purchase path (added by the human) | `PurchaseRbtc` row loop ≈720 per row (≈0.7%); whole path estimated ≈1.5–2k per row | Reject | Compute is ≈4.2k of a ≈24k row, so even deleting all of it caps at ≈4%. It would override invariant 5, copy the rBTC encoding out of its helpers (invariant 13), and hand-maintain event and storage layout the compiler checks today. |
| `unchecked` credit add in `_creditRbtc` (added by the human) | ≈45 per row | **Add** | For consistency with the protocol's other justified `unchecked` blocks, not for gas. Each credit is a share of rBTC the contract measured receiving, so the sum stays near rBTC's supply (≈2⁸⁵); OpenZeppelin's ERC-20 uses the same argument. Stays inside `_creditRbtc`, so invariant 13 holds. |

Approved for implementation: removing the idle ledger (with its invariant test), dropping
`FeeHandler__FeeTransferred`, and the `unchecked` credit add. Each ships in its own commit in the R87
PR, with consumer issues for the removed event, the removed `getUsersIdleTokenBalance` getter, and the
idle `AmountAdjusted` event and error that go with the ledger.

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

- [ ] **Measure each candidate before asking.**
  - Use Foundry, on both profiles, against the R86 head.
  - Convert every figure to Rootstock gas with
    [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). Count writes per slot wherever storage
    changes, as `AGENTS.md` requires.
  - One-off harnesses do not ship unless the human approves the candidate. Keep a rejected harness only
    as a commit link, the way R84 did.
- [ ] **For `optimizer_runs`**, measure at least one purchase batch, deployed size and deploy gas at
  200 against one or two higher values.
  - At each value, check `test/gas/R81PackedSlotWritesGas.t.sol` with the helpers as they are.
    - Why: a higher value may inline `_storePurchaseProgress` into its caller and split the merged
      writes again.
  - Then inline `_storeNewSchedule` and `_storePurchaseProgress` back into `createDcaSchedule` and
    `_rBtcPurchaseChecksEffects`, and run the same tests. That shows whether the helpers are still
    needed.
- [ ] **Present one table to the human**, listing each candidate's:
  - measured Rootstock saving, per row or per batch;
  - share of a typical batch;
  - cost;
  - recommendation.
- [ ] **If one or more are approved:**
  - Branch from the latest open relaunch PR's head.
  - Implement each approved candidate in its own commit, with tests.
  - Open consumer issues for any event change (`AGENTS.md` **Consumer follow-up**).
  - Open one PR.
- [ ] **If none are approved:** no branch and no PR. Report the verdicts in the chat, and change no
  docs, including the deferred record.

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

- **Measurement only:** the commands used, recorded in the chat.
- **If a PR opens:** the gate for its tier under **Scale the gate to the change** in `AGENTS.md`. For
  any `src/` or `foundry.toml` change, that means `make check`, `make check-deploy`,
  `make fork-sovryn` and `make fork-tropykus`.
  - For `optimizer_runs`, also `make fork-dex-path`. Re-record every gas figure the PR cites.

## Success criteria

- [ ] Every candidate has a measured Rootstock figure and a verdict from the human.
- [ ] Either a PR carries the approved candidates, or no PR is opened because none were approved.
- [ ] Any PR updates the gas audit's deferred record to match what it ships.

## Reviewer checklist

- [ ] Only human-approved candidates are implemented.
- [ ] Protocol invariants in `AGENTS.md` still hold, unless an approved candidate changes one and says so.
- [ ] Every Rootstock figure shows how it was derived.
- [ ] Consumer issues are opened for any event change.

## ABI / deploy / cutover impact

It depends on what is approved:
- **Removing the idle ledger** removes the `getUsersIdleTokenBalance` getter.
- **The event candidates** change events, so they are cutovers.
- **The fee sweep** adds an entry point.
- **Balance reuse and `optimizer_runs`** change no ABI.
