# R77 — Accumulated rBTC storage sentinel

Status: **implemented** · GitHub [#138](https://github.com/BitChillRSK/dca-contracts/pull/138) · Assigned: yes · Optional/further-review: no · Order: stack on R74 ([#137](https://github.com/BitChillRSK/dca-contracts/pull/137))

## Objective

Encode each handler's per-user accumulated-rBTC slot so a full withdrawal leaves a nonzero sentinel
instead of clearing storage. The next credit for that user is then a cheaper nonzero-to-nonzero
`SSTORE`, while getters and withdrawals still expose and pay the complete claimable balance.

## Background

`PurchaseRbtc` stores claimable rBTC in `s_usersAccumulatedRbtc[user]` and writes `0` on full
withdrawal. The next purchase for that user then pays a zero-to-nonzero `SSTORE` (`SET`) again. On
Rootstock that is a flat 20,000 vs 5,000 `RESET` — there is no EIP-2929 cold/warm schedule; what
matters is keeping the slot nonzero so the next credit is a RESET.

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
credited, and moving storage-clear economics onto the user at full withdrawal.

### Rootstock economics (production schedule)

On Rootstock, SSTORE is Petersburg-style: `SET = 20,000`, `RESET = CLEAR = 5,000`, `REFUND = 15,000`,
with refunds capped at `gasUsed / 2`. See [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md).
Because `SET − REFUND = RESET`, keeping the slot non-zero is **gas-neutral for the system**; it only
moves cost between parties.

| Per withdraw-and-rebuy cycle, on Rootstock | without sentinel | with sentinel | delta |
|---|---:|---:|---:|
| Swapper's first credit after a withdrawal | 20,000 SET | 5,000 RESET | **−15,000** |
| User's full withdrawal | 5,000 CLEAR − 15,000 refund = −10,000 | 5,000 RESET | **+15,000** |
| System net | | | **0** |

Three consequences, in order:

1. **This is the intended effect.** R77 exists to move 15,000 gas per cycle off the swapper — a
   recurring protocol operating cost paid on every post-withdraw re-credit forever — and onto users'
   individual, occasional withdrawals. That transfer is the approved rationale and it lands at full
   size on Rootstock, larger on the user side than the Ethereum arithmetic suggested (15,000, not
   4,800). The 15,000 clear refund is fully realized whenever withdraw `gasUsed ≥ 30,000` (cap is
   `gasUsed / 2`), which every real withdrawal exceeds.
2. **It creates no net system value**, and the earlier “≈12,300 net” figure was wrong. That number was
   an artifact of EIP-3529, which deliberately made Ethereum's clear refund smaller than its
   set/reset gap. Rootstock never adopted it, so the two sides cancel exactly.
3. **The encoding is not free.** The always-on Foundry-measured overhead is **+298** one-row /
   **+938** five-row same-buyer on ordinary credits — real deadweight paid on every non-sentinel
   credit, and the honest cost of the transfer. Those figures are Foundry / Cancun measurements, not
   Rootstock bills.

### Foundry / Cancun regression pin (not a Rootstock saving)

`test/gas/R77AccumulatedRbtcSentinelGas.t.sol` pins `EXPECTED_COLD_SAVING = 17_105` under Foundry's
Cancun schedule (cold SET − cold RESET after `vm.cool`). That number is a **same-build regression
pin**. It is **not** the Rootstock operator saving (which is 15,000 on the SET→RESET substitution
above). Do not quote 17,105 / ≈17,100 / ≈4,300 / −4,800 / ≈12,300 as production Rootstock economics.

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
- `AGENTS.md` (invariant 13; Foundry-vs-Rootstock gas methodology under Tests and done-gate)
- `test/unit/PurchaseRbtcTest.t.sol`
- `test/gas/R77AccumulatedRbtcSentinelGas.t.sol`
- `docs/relaunch/R77-accumulated-rbtc-storage-sentinel.md`
- `docs/relaunch/ROOTSTOCK-GAS-SCHEDULE.md`
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
- [x] Rootstock economics recorded: −15,000 swapper / +15,000 user / 0 system net per withdraw-and-rebuy;
      Foundry pin `EXPECTED_COLD_SAVING = 17_105` labelled as Cancun regression only; always-on encoding
      overhead +298 / +938 kept as Foundry deadweight. No open product decisions remain.
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
