# R53 — Re-baseline every recorded size and gas number against the optimized profile

Status: **not started** · Assigned: no · Optional/further-review: no

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
stack-too-deep argument. Those are re-judgements for their own PRs. This PR only fixes the record. (The
R52 allowlist placement was the third such case and #104 already re-judged it, moving policy onto
`PurchaseUniswap`.)

## Open product decisions

**None.** `optimizer_runs = 200` and CI inheritance were settled in #104.

## Scope

- [ ] Re-measure with a full `forge build --sizes` (not `--match-*`) and record `DcaManager`,
      `OperationsAdmin`, `IdleDocHandlerMoc`, all three `*DocHandlerMoc`, and all three
      `*Erc20HandlerDex` runtime sizes and margins.
- [ ] Re-measure `testSinglePurchase` and `testBatchPurchasesOneUser` gas on the MoC/Sovryn lane.
- [ ] Correct the recorded runtime/margin and gas figures in `docs/relaunch/README.md`,
      `IMPLEMENTATION_ORDER.md`, and the R18 / R31 / R42 / R50 / R51 specs. Where an entry records a
      decision made against the old number, **leave the entry and append the corrected figure** — do not
      rewrite the history of why a shipped PR chose what it chose.
- [ ] Grep the docs for any remaining claim that the measurement basis is unoptimized, or that a contract
      is near EIP-170, and correct it.
- [ ] Flag, without acting on, every design decision whose stated justification was bytecode scarcity, so
      each can be re-judged in its own PR.

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

- [ ] Every runtime size and EIP-170 margin quoted in `docs/relaunch/` matches a fresh
      `forge build --sizes`, or is explicitly labelled as the historical figure a past decision used.
- [ ] No document still describes the measurement basis as unoptimized.
- [ ] Decisions justified by bytecode scarcity are listed for re-judgement, and none are re-judged here.
- [ ] No file outside `docs/` changed.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] History of shipped decisions is annotated, not rewritten.
- [ ] Numbers were taken from a full build, not a filtered one.
- [ ] No `src/`, `script/`, `test/`, or build-config file is in the diff.

## ABI / deploy / cutover impact

None. Documentation only. The bytecode change that motivates it ships in #104.
