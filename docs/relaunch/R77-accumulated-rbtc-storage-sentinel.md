# R77 — Accumulated rBTC storage sentinel

Status: **implemented** · GitHub [#138](https://github.com/BitChillRSK/dca-contracts/pull/138) · Assigned: yes · Optional/further-review: no · Order: stack on R74 ([#137](https://github.com/BitChillRSK/dca-contracts/pull/137))

## Objective

Encode each handler's per-user accumulated-rBTC slot so a full withdrawal leaves a nonzero sentinel
instead of clearing storage. The next credit for that user is then a cheaper nonzero-to-nonzero
`SSTORE`, while getters and withdrawals still expose and pay the complete claimable balance.

## Background

`PurchaseRbtc` stores claimable rBTC in `s_usersAccumulatedRbtc[user]` and writes `0` on full
withdrawal. The next purchase for that user pays a zero-to-nonzero `SSTORE` again. Storage warmth
does not survive across transactions; what matters is keeping the slot nonzero.

Leaving one claimable wei behind would save the same gas but would permanently show dust in
`getAccumulatedRbtcBalance` and complicate `withdrawAllAccumulatedRbtc`'s zero-balance skip. The
cleaner encoding is:

- `0` means the user has never been credited on this handler.
- A live slot stores `claimableRbtc + 1` (including the post-withdraw sentinel `1`, which means
  claimable `0`).
- Getters return `stored == 0 ? 0 : stored - 1`.
- Full withdrawal writes `1` and transfers the complete decoded claim.
- Subsequent purchases add into the nonzero slot.

Tradeoffs accepted by this PR: permanent one-slot state per user×handler that has ever been
credited, and loss of the user's storage-clear refund on full withdrawal.

**Amortized framing (what decides whether the permanent state is worth it):** the ≈17,100 gas
operator saving fires only on a purchase whose buyer fully withdrew since their last credit. For a
weekly-DCA user who withdraws monthly that is roughly one row in four, so **≈4,300 gas/row** expected
operator saving — not 17,100 on every tick. Of the peak 17,100, **4,800 is a transfer from the user**
(EIP-3529 clear refund forgone on every full `withdrawAccumulatedRbtc`; ×N in
`withdrawAllAccumulatedRbtc`), not new value: the protocol-level net per withdraw-and-rebuy cycle is
therefore **≈12,300**. Peak cold re-credit delta (SSTORE_SET − SSTORE_RESET) is still what the harness
measures (**17,105**, pinned as `EXPECTED_COLD_SAVING`).

`DcaManager` needs no logic change: it already reads and skips through
`IPurchaseRbtc.getAccumulatedRbtcBalance`, which must keep returning the decoded claimable amount.

## Open product decisions

**none** — the human accepted the encoded-sentinel tradeoff (2026-09-18) and asked for a dedicated
stacked implementation PR rather than folding it into R74.

## Scope

- [x] Encode `s_usersAccumulatedRbtc` as `claimable + 1` when the slot is live; leave `0` only for
      never-credited users. Mapping is `private`; credit through `_creditRbtc`, decode through
      `_claimableRbtc` / `_withdrawRbtcChecksEffects` only (`AGENTS.md` invariant 13 — compile-enforced).
- [x] Decode in `getAccumulatedRbtcBalance` and in `_withdrawRbtcChecksEffects`.
- [x] On full withdrawal, write sentinel `1` and transfer the full decoded claim (never leave
      claimable dust).
- [x] On credit, skip the storage write when the row's allocated rBTC is `0` so a never-credited user
      is not marked live by a zero floor allocation.
- [x] Document the encoding in `PurchaseRbtc` NatSpec (durable reason, no R-id in `src/`); keep the
      interface getter return tag free of storage-gas detail.
- [x] Unit-test: full withdraw pays everything, getter stays `0`, raw slot is `1`, a later purchase
      credits and withdraws cleanly again; never-credited withdraw still reverts / withdraw-all skips.
- [x] Gas benchmark: cold first credit vs cold re-credit after full withdraw (setUp + `vm.cool`),
      and record the delta in the PR / spec success notes.
- [x] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md` with R77.

## Out of scope

- [ ] Leaving claimable dust, changing withdraw signatures, or exposing raw storage on the ABI.
- [ ] Packing rBTC into another mapping or merging with stablecoin books (rejected in R50).
- [ ] Fee, min-purchase, or period changes (R74).
- [ ] DcaManager behavior changes beyond relying on the already-decoded getter.
- [ ] Consumer cutover work unless a getter semantic actually changes (it must not).

## Files likely touched

- `src/PurchaseRbtc.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `AGENTS.md` (invariant 13)
- `test/unit/PurchaseRbtcTest.t.sol`
- `test/gas/R77AccumulatedRbtcSentinelGas.t.sol`
- `docs/relaunch/R77-accumulated-rbtc-storage-sentinel.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`

## Required tests

```bash
forge test --match-contract PurchaseRbtcTest
forge test --match-path test/gas/R77AccumulatedRbtcSentinelGas.t.sol -vv
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract RbtcWithdrawalTest
make check
make fork-sovryn
make fork-tropykus
```

Assert that after a full withdraw the getter is `0`, the transferred amount equals the pre-withdraw
claim, a second purchase credits the full measured amount again, and a never-credited user still has
no withdrawable balance. The gas test prints first-credit vs post-withdraw re-credit costs; the
re-credit must be materially cheaper (on the order of the zero-to-nonzero vs nonzero-to-nonzero
`SSTORE` gap). Fork tests add no new fork-only assertion but remain required before push.

## Success criteria

- [x] Users can always withdraw their complete claimable balance; getters never report sentinel dust.
- [x] After a full withdraw the storage slot stays nonzero (`1`); the next credit avoids a
      zero-to-nonzero `SSTORE`.
- [x] `withdrawAllAccumulatedRbtc` still skips zero-claimable handlers via the decoded getter.
- [x] Measured re-credit gas saving is recorded with amortized framing (**≈4,300 gas/row** expected for
      weekly-DCA / monthly-withdraw; peak cold **≈17,100** / harness pin **17,105**; **≈12,300** net per
      withdraw-and-rebuy after the −4,800 user clear-refund transfer); no open product decisions remain.
- [x] `make check`, `make fork-sovryn`, and `make fork-tropykus` pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Encoding is confined to `PurchaseRbtc`; `DcaManager` does not reimplement decode logic.
- [ ] Protocol invariants in `AGENTS.md` still hold (especially invariant 3 — full claim pays the signer).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none — selectors, events, and getter return meaning (claimable wei) are unchanged. Only the
  internal storage encoding changes.
- Scripts: none.
- Cutover: none for consumers that already use `getAccumulatedRbtcBalance`. Indexers that read raw
  handler storage for this slot (rather than the getter) would mis-decode by one wei; that is not a
  supported integration path. No consumer issues unless review finds a raw-storage reader.
