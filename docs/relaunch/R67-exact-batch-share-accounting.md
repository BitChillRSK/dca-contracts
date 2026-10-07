# R67 — Exact batch share accounting

Status: **in progress** · Assigned: yes · Optional/further-review: no (approved 2026-09-06) · PR: [#122](https://github.com/BitChillRSK/dca-contracts/pull/122)

## Objective

Lending batches debit users for exactly the number of protocol shares the handler
redeems, eliminating the orphan-share drift from the previous two-stage ceiling.

## Background

`LendingErc20Handler._batchRetrieveStablecoin` first rounded the aggregate stablecoin
request into one `totalSharesToRedeem`, then assigned each row a rounded-up pro-rata
share of that total. The per-row ceilings could sum to slightly more than the aggregate
shares actually redeemed (at most `n − 1` shares for `n` rows). Virtual books therefore
lost shares the protocol never burned, leaving a permanent unclaimed balance in the
handler's lending position.

## Open product decisions

**Answered 2026-09-06**

- Does removing the bounded share-dust discrepancy justify changing the batch
  redemption arithmetic? **Yes** — the exact-sum shape is shorter, matches single-redeem
  math, and measured ~628 gas cheaper on the share loop (drops the aggregate `mulDiv`).
- If yes, should each row independently round up and the protocol redeem the exact sum,
  accepting the corresponding small increase in underlying requested? **Yes.**

## Scope

**Later decision:** [R114](./R114-nethermind-audit-followups.md) retains exact-sum share consumption
and supersedes this spec's shortfall revert. A positive-value short row clamps to its buyer's shares
and reduces its funding weight; only a zero-value row raises `InsufficientShares`.

- [x] Measure the maximum and observed difference between shares debited and shares
      redeemed across supported lending adapters and representative batch sizes.
- [x] Sum each row's independently calculated share debit and redeem exactly that sum.
- [x] Preserve the existing revert when any row's buyer lacks the required shares.
- [x] Preserve measured stablecoin accounting and pro-rata rBTC allocation from actual
      cash received.

## Out of scope

- [ ] Skipping or clamping an underfunded row.
- [ ] Returning per-row funding results to `DcaManager`.
- [ ] Moving schedule effects after the handler call.
- [ ] Any change to idle handlers, batch calldata, min-out semantics, or the protected
      purchase window.

## Files likely touched

- `src/LendingErc20Handler.sol`
- `test/unit/LendingErc20HandlerRedeemTest.t.sol`
- Dedicated lending-handler tests only where adapter rounding differs materially

## Required tests

- A multi-user batch debits exactly the sum of shares redeemed at the protocol.
- Repeated rows for one buyer debit that buyer by exactly their rows' combined share
  requirement.
- An insufficient-share row continues to revert the whole handler batch with
  `TokenLending__InsufficientShares`.
- Measured stablecoin receipt and rBTC allocation invariants remain unchanged.
- Record gas against the parent revision for 1, 5, 10, 50, and 200 rows.
- Fork tests add no R67-specific assertions unless measurement finds adapter-specific
  behavior.

## Success criteria

- [x] The product decision is recorded before Solidity changes.
- [x] If implemented, total virtual shares debited equals total protocol shares redeemed
      for every successful batch.
- [x] No R66 behavior or ABI change is pulled into this item.
- [x] The full local and fork gates pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Measurements distinguish harmless bounded dust from a solvency or withdrawal impact.
- [ ] Existing insufficient-funding behavior remains explicit.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none expected.
- Scripts: none.
- Cutover: none expected; open a monitoring follow-up only if an existing event's field
  meaning changes.

## Measurement (pre-change)

Pure-math probe at rate `1_000_123_456_789_012_345` (ceilings bite; exact `1e18` often
shows zero dust):

| Rows | Orphan shares (debited − burned) | Share-loop gas: exact − current |
|---:|---:|---:|
| 1 | 0 | −628 |
| 5 | 2 | −628 |
| 10 | 5 | −628 |
| 50 | 25 | −628 |
| 200 | 100 | −628 |

Bound is `n − 1`. Exact-sum burns those shares into the purchase instead of stranding
them. Full-tick gas is dominated by lending/MoC/Uniswap; the share-loop delta is a flat
~600 gas either way.
