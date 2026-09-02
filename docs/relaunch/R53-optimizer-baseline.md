# R53 — Re-baseline every recorded size and gas number against the optimized profile

Status: **implemented** · Assigned: yes · Optional/further-review: no

## Objective

`[profile.default]` never enabled the solc optimizer and forge defaults it to `false`, so every runtime
size, EIP-170 margin, and gas figure recorded across `docs/relaunch/` was measured on unoptimized
bytecode. R52 / GitHub [#104](https://github.com/BitChillRSK/dca-contracts/pull/104) turns the optimizer
on and corrects its *own* figures. This PR corrects everyone else's, so later design decisions stop being
made against a budget that no longer exists.

## What #104 already did, and what it did not

Landed in #104, not here:

- `[profile.default]`: `optimizer = true`, `optimizer_runs = 200`, `via_ir = false`. `[profile.ci]`
  inherits it; no separate optimizer key was added there.
- Removal of the vestigial `[profile.deploy]`.
- The measurement rule at the top of `IMPLEMENTATION_ORDER.md` and its `AGENTS.md` mirror, rewritten so
  the basis is *optimized* no-IR rather than unoptimized no-IR.
- Re-proving R23's Rootstock testnet + Blockscout baseline at the new settings
  (`script/DeployOptimizerProof.s.sol`). That proof is #104's merge blocker, not R53's deliverable.
- Correct optimized figures for `DcaManager`, `OperationsAdmin`, and all three Dex leaves in the R52
  spec, `docs/relaunch/README.md`'s R52 entry, and the PR body.

Not done anywhere yet, and the whole of this PR: every other recorded number.

## Background

Before the flip, `forge config` reported:

```
optimizer = false
optimizer_runs = 200      # set, but inert while the optimizer is off
via_ir = false
```

The cause was visible at the bottom of the old `foundry.toml`: a `# optimizer = false` line commented out
under `[profile.deploy]` with the note "This just for quicker testing". Commenting it out restored
`[profile.deploy]`, but `[profile.default]` was never opted in, and forge's own default is `false`.

Measured on `DcaManager`, and on the purchase hot path via the MoC/Sovryn lane:

| Config | DcaManager runtime | margin | `testSinglePurchase` | `testBatchPurchasesOneUser` |
| --- | --- | --- | --- | --- |
| optimizer off, no IR (as recorded) | 23,703 | 873 | 283,711 | 2,244,557 |
| optimizer on, no IR (#104 onward) | 13,767 | 10,809 | 243,817 (−14.1%) | 1,562,720 (−30.4%) |
| optimizer on, via IR | 11,039 | 13,537 | 239,142 | 1,503,278 |

The optimizer alone reclaims ~9.9 KB of runtime and 14–30% of purchase gas.

This matters beyond the numbers: several shipped decisions were justified by bytecode scarcity that was an
artifact of the measurement. The migration gate chose manual exit/re-entry partly because
"`SovrynErc20HandlerDex` has 426 bytes of runtime margin"; R51's `_creditBuyers` discussion is a no-IR
stack-too-deep argument. R53 only fixes the record and lists them; it does not reopen them. (The
R52 allowlist placement was the third such case and #104 already re-judged it, moving policy onto
`PurchaseUniswap`.) [#111](https://github.com/BitChillRSK/dca-contracts/pull/111) later closed the
list: four shipped choices stand on their non-size merits, and the two rejected options stay rejected.

## Open product decisions

**None.** `optimizer_runs = 200` and CI inheritance were settled in #104.

## Scope

- [x] Re-measure with a full `forge build --sizes` (not `--match-*`) and record `DcaManager`,
      `OperationsAdmin`, `IdleDocHandlerMoc`, all three `*DocHandlerMoc`, and all three
      `*Erc20HandlerDex` runtime sizes and margins.
- [x] Re-measure `testSinglePurchase` and `testBatchPurchasesOneUser` gas on the MoC/Sovryn lane.
- [x] Correct the recorded runtime/margin and gas figures in `docs/relaunch/README.md`,
      `IMPLEMENTATION_ORDER.md`, and the R18 / R31 / R42 / R50 / R51 specs. Where an entry records a
      decision made against the old number, **leave the entry and append the corrected figure** — do not
      rewrite the history of why a shipped PR chose what it chose.
- [x] Grep the docs for any remaining claim that the measurement basis is unoptimized, or that a contract
      is near EIP-170, and correct it.
- [x] Flag, without acting on, every design decision whose stated justification was bytecode scarcity.
      (Closed later in [#111](https://github.com/BitChillRSK/dca-contracts/pull/111): no further
      re-judgement PRs — see [Bytecode-scarcity decisions (closed)](#bytecode-scarcity-decisions-closed).)

## Out of scope

- [ ] The optimizer pin itself, `[profile.deploy]` removal, and the Rootstock/Blockscout re-proof (all #104).
- [ ] `via_ir` and solx, including whether to repair `ZeroTokenPurchaseUniswap` (R55).
- [ ] Re-judging the migration gate, R51's `_creditBuyers`, or R39 — this PR's numbers unblock those.
- [ ] Any `src/`, `script/`, `test/`, `foundry.toml`, or `Makefile` change. This is a documentation PR.

## Files likely touched

- `docs/relaunch/README.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/R18-storage-packing.md`, `R31-handler-abi-trim.md`, `R42-swapper-batcher.md`,
  `R50-packing-follow-up.md`, `R51-per-batch-min-rbtc-out.md`

## Required tests

No behavior changes, so no new tests. Evidence for the numbers:

- `forge build --sizes` under `[profile.default]`, full build.
- `make check` to confirm the tree is green at the settings the figures describe.
- Gas via the MoC/Sovryn lane for the two named tests.

## Success criteria

- [x] Every runtime size and EIP-170 margin quoted in `docs/relaunch/` matches a fresh
      `forge build --sizes`, or is explicitly labelled as the historical figure a past decision used.
- [x] No document still describes the measurement basis as unoptimized.
- [x] Decisions justified by bytecode scarcity are listed, and none are re-judged here (queue closed in #111).
- [x] No file outside `docs/` changed.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] History of shipped decisions is annotated, not rewritten.
- [ ] Numbers were taken from a full build, not a filtered one.
- [ ] No `src/`, `script/`, `test/`, or build-config file is in the diff.

## ABI / deploy / cutover impact

None. Documentation only. The bytecode change that motivates it ships in #104.

## As implemented

Measured 2026-09-02 on the R58 head (`docs/r53-optimizer-baseline`, stacked on
[#108](https://github.com/BitChillRSK/dca-contracts/pull/108)) under `[profile.default]`:
solc 0.8.36 / `cancun`, `optimizer = true`, `optimizer_runs = 200`, `via_ir = false`.

Full `forge build --sizes` (no `--match-*`), EIP-170 24,576 B:

| Contract | runtime (B) | margin (B) |
|---|---:|---:|
| `DcaManager` | 13,767 | 10,809 |
| `OperationsAdmin` | 3,227 | 21,349 |
| `IdleDocHandlerMoc` | 7,539 | 17,037 |
| `SovrynDocHandlerMoc` | 10,724 | 13,852 |
| `LayerBankDocHandlerMoc` | 10,933 | 13,643 |
| `TropykusDocHandlerMoc` | 10,864 | 13,712 |
| `SovrynErc20HandlerDex` | 15,479 | 9,097 |
| `LayerBankErc20HandlerDex` | 15,692 | 8,884 |
| `TropykusErc20HandlerDex` | 15,623 | 8,953 |

Gas, MoC/Sovryn lane (`SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC`):
`testSinglePurchase` **243,790**, `testBatchPurchasesOneUser` **1,562,441**.

Two deltas against the figures #104 recorded, both from source that landed between #104 and this branch,
not from any build-setting change: the three Dex leaves are 100 B larger (R56 /
[#107](https://github.com/BitChillRSK/dca-contracts/pull/107), which the R56 entry already records at
these values), and the two gas numbers are 27 and 279 lower than #104's 243,817 / 1,562,720.
`DcaManager` and `OperationsAdmin` are byte-identical to #104.

The table lives in one place — [Measurement basis](./README.md#measurement-basis) in
`docs/relaunch/README.md` — and every entry or spec that still quotes a pre-#104 number now says so
beside the number and points there, rather than each carrying its own copy of the table to drift.

**These are today's head, not a rebuild of each historical commit.** A delta between an old entry and
this table therefore mixes the optimizer flip with every source change since, and the annotations say so.
For the flip alone, on one commit, #104's measurement stands: `DcaManager` 23,703 → 13,767 B
(margin 873 → 10,809), `testSinglePurchase` 283,711 → 243,817 (−14.1%), `testBatchPurchasesOneUser`
2,244,557 → 1,562,720 (−30.4%).

## Bytecode-scarcity decisions (closed)

<a id="decisions-flagged-for-re-judgement"></a>

Each was argued, in whole or in part, from bytecode scarcity that the unoptimized measurement created.
**R53 re-judged none of them** — it only annotated the record. [#111](https://github.com/BitChillRSK/dca-contracts/pull/111)
closed the follow-up queue on 2026-09-02: nothing here awaits its own re-judgement PR.

| Decision | Status | The bytecode claim | Now | What still holds |
|---|---|---|---|---|
| R13 migration gate — manual exit/re-entry, no cooperative migration | **Closed — decided against** cooperative migration | "`SovrynErc20HandlerDex` has 426 bytes of runtime margin", so a source-side migration "does not fit" | 15,479 B, margin 9,097 — it would fit | Reasons 1, 3, 4: migration redeems through the same path that would be broken, it is the highest-value target on immutable contracts, and generation 2 can still ship the hook. Do not reopen. |
| R50 — merged per-user stablecoin/rBTC slot | **Closed — decided against** (tried and reverted in R50) | one of three objections was "~660 bytes of dex-handler EIP-170 margin (1,544 → 880)" | ~8.9 KB of Dex margin — that objection is void | `StablecoinSource` is still the wrong home for rBTC state, and the `uint128` share cap is still venue-dependent. Do not reopen. |
| R42 — integrate the grouped loop into `DcaManager` | **Closed — shipped / stands** | "893 bytes below EIP-170 … is the real deployment constraint"; headroom traded for hot-path gas | 13,767 B, margin 10,809 — the trade cost a fraction of what it looked like | The gas measurement that decided it (344,723 vs 347,186 vs 361,133) is unaffected; the shipped choice is the cheap one either way |
| R39 — delete `buyRbtc` | **Closed — shipped / stands** | partly "Dex bytecode … R31 left a few hundred bytes of margin before R9" | ~8.9 KB | One purchase pipeline instead of two, and a length-1 batch is the same operational path; the ABI is already frozen and shipped |
| R31 — land the ABI trim before R9 | **Closed — shipped / stands** | "R30 left only 329–452 bytes of EIP-170 margin", plus a conditional follow-up if `supportsInterface` did not fit | ~8.9 KB | One canonical getter per value; the trim and the ERC-165 class check both shipped |
| R51 — no `_creditBuyers` extraction | **Closed — shipped / stands** | the smallest of three effects, "17 bytes smaller on every Dex handler" | 17 B against ~8.9 KB rather than ~1.1 KB | Everything that decided it: the function was one stack slot over, the optimizer does **not** relieve stack-too-deep (R51 checked, and it still holds with the optimizer on), and only via-IR would — which is R55's call. The gas wins are unaffected |

`ZeroTokenPurchaseUniswap` and anything else via-IR touches stays with [R55](./R55-solx-and-ir-evaluation.md).
[R54](./R54-schedule-top-up-from-interest.md) was already written against the optimized budget and needs
no correction here — its `+600 B` against 10,209 B of margin is the post-flip figure.

## Files changed

Beyond the spec's list: `R9`, `R13`, `R30`, `R34`, `R36`, `R38`, `R39`, `R43`, `R44`, `R45`, `R46`, `R47`
each carry a recorded size or gas figure and now label it pre-optimizer. `R13` also gets the appended
correction for the migration gate's void bytecode reason; the gate itself stays closed (manual exit).
