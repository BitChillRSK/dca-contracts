# R53 — Turn the solc optimizer on, and re-baseline every size and gas number

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

`[profile.default]` never enables the solc optimizer and forge defaults it to `false`, so every
runtime size, EIP-170 margin, and gas figure recorded anywhere in `docs/relaunch/` was measured on
unoptimized bytecode. Enable the optimizer, re-measure, and correct the recorded numbers so later
design decisions stop being made against a budget that does not exist.

## Background

`forge config` on this repo reports:

```
optimizer = false
optimizer_runs = 200      # set, but inert while the optimizer is off
via_ir = false
```

`[profile.ci]` inherits `[profile.default]`, so the CI lanes are unoptimized too. The cause is
visible at the bottom of `foundry.toml`: a `# optimizer = false` line commented out under
`[profile.deploy]` with the note "This just for quicker testing". Commenting it out restored
`[profile.deploy]`, but `[profile.default]` was never opted in and forge's own default is `false`,
so the main profile has been unoptimized for the life of the relaunch.

Measured on `DcaManager` at `4b407d4`, and on the purchase hot path via the MoC/Sovryn lane:

| Config | DcaManager runtime | margin | `testSinglePurchase` | `testBatchPurchasesOneUser` |
| --- | --- | --- | --- | --- |
| optimizer off, no IR (today) | 23,703 | 873 | 283,711 | 2,244,557 |
| optimizer on, no IR | 13,767 | 10,809 | 243,817 (−14.1%) | 1,562,720 (−30.4%) |
| optimizer on, via IR | 11,039 | 13,537 | 239,142 | 1,503,278 |

The optimizer alone reclaims ~9.9 KB of runtime and 14–30% of purchase gas. `LayerBankErc20HandlerDex`
moves from a recorded 23,534 B / 1,042 B margin to 14,844 B / 9,732 B margin; `OperationsAdmin` from
5,019 B unoptimized to 4,377 B under IR.

This matters beyond the numbers: several shipped decisions were justified by bytecode scarcity that
was an artifact of the measurement. `IMPLEMENTATION_ORDER.md` records the R52 allowlist living on
`OperationsAdmin` because "an earlier combined prototype exceeded EIP-170 when policy lived on the
Dex leaf"; the migration gate chose manual exit/re-entry partly because "`SovrynErc20HandlerDex` has
426 bytes of runtime margin"; R51's `_creditBuyers` extraction is a no-IR stack-too-deep workaround.
Those are re-judgements for their own PRs, not this one — this PR only fixes the measurement and the
recorded numbers.

`IMPLEMENTATION_ORDER.md` currently pins "all EIP-170 decisions use `[profile.default]` and
`via_ir = false`", mirrored in `AGENTS.md`. That rule sensibly refuses to bank on the IR pipeline,
but in practice it froze *unoptimized* measurement as policy. It must be rewritten, not deleted:
the no-IR half stays until R55 settles the pipeline question.

**via_ir is deliberately not part of this PR.** A full `forge build` under `via_ir = true` fails with
solc error 1284 on `ZeroTokenPurchaseUniswap` (`test/unit/PurchaseUniswapSettingsTest.sol:440`),
whose constructor reverts unconditionally by design, so the optimizer drops its immutable
assignments while the runtime still reads them. `forge test --match-*` can appear to succeed because
forge compiles sparsely and may never reach that file. The optimizer alone builds the whole tree,
tests included, with no change to that contract.

## Open product decisions

1. **`optimizer_runs` value.** `200` is already written in `foundry.toml` and is the conventional
   default. A higher value trades runtime size for hot-path gas. Recommend keeping `200` for this
   PR so the change is one variable, and revisiting only if R55 shows the hot path still hurts.
2. **Does CI adopt it in the same PR?** Recommend yes: leaving `[profile.ci]` unoptimized means CI
   proves nothing about deployed bytecode.

## Scope

- [ ] `[profile.default]`: `optimizer = true`. Keep `optimizer_runs = 200`. Keep `via_ir = false`.
- [ ] Confirm `[profile.ci]` inherits it; do not add a separate optimizer key there.
- [ ] Re-run R23's toolchain proof at the new settings: Rootstock testnet (chain 31) acceptance plus
      Blockscout verification of `OperationsAdmin`, `DcaManager`, and one handler. The existing proof
      was obtained with the optimizer off and does not carry over. Record the tx hashes.
- [ ] Rewrite the `[profile.default]` / `via_ir = false` rule in `IMPLEMENTATION_ORDER.md` and
      `AGENTS.md` so it pins *optimized, no-IR* as the measurement basis.
- [ ] Correct the recorded runtime/margin figures in `docs/relaunch/README.md` and
      `IMPLEMENTATION_ORDER.md` for `DcaManager`, both Dex handlers, and `OperationsAdmin`. Where a
      historical entry records a decision made against the old number, leave the entry and append the
      corrected figure — do not rewrite the history of why a shipped PR chose what it chose.

## Out of scope

- [ ] `via_ir` (R55 owns the pipeline question, including whether to fix `ZeroTokenPurchaseUniswap`).
- [ ] solx (R55).
- [ ] Re-judging R52 allowlist placement, the migration gate, R51's `_creditBuyers`, or R39. Those
      belong to their own PRs, which this PR's numbers unblock.
- [ ] Any `src/` change. If a test fails only under the optimizer, that is a finding to report, not
      a licence to edit `src/` here.

## Files likely touched

- `foundry.toml`
- `AGENTS.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`

## Required tests

The full done-gate, because this changes generated code everywhere:

- `make check` — `forge build`, `make moc-none`, `make moc-layerbank`, `make moc-sovryn`,
  `STABLECOIN_TYPE=USDRIF make dex-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-layerbank`,
  `STABLECOIN_TYPE=USDT0 make dex-layerbank`, `make invariants-sovryn`.
- `make fork-sovryn` and `make fork-tropykus` before push (needs `RSK_MAINNET_RPC_URL`).
- Record before/after runtime sizes for `DcaManager`, `LayerBankErc20HandlerDex`,
  `SovrynErc20HandlerDex`, and `OperationsAdmin` via `forge build --sizes`.
- Record before/after gas for `testSinglePurchase` and `testBatchPurchasesOneUser` on the
  MoC/Sovryn lane.

Behaviors to assert: **none new**. Every existing test must pass unchanged. A test that passes only
unoptimized is a real defect and must be reported, not adjusted.

## Success criteria

- [ ] `forge config` reports `optimizer = true`, `optimizer_runs = 200`, `via_ir = false`.
- [ ] Full `forge build` succeeds including the test tree, with `ZeroTokenPurchaseUniswap` unmodified.
- [ ] Every lane in the done-gate passes with no test edits.
- [ ] Rootstock testnet + Blockscout verification re-proved at the new settings, tx hashes recorded.
- [ ] Recorded sizes/margins in the docs match a fresh `forge build --sizes`.
- [ ] No `src/` file changed.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold; none are changed by this PR.
- [ ] No test was edited to accommodate the optimizer.
- [ ] The rewritten measurement rule still forbids banking on `via_ir`.
- [ ] History of shipped decisions is annotated, not rewritten.

## ABI / deploy / cutover impact

- ABI: none. Selectors, events, errors, and storage layout are unchanged; `forge inspect`
  `methodIdentifiers` and `storageLayout` must be identical before and after.
- Scripts: none, but deployed bytecode changes, so any prior verification artifact is stale.
- Cutover: deployed bytecode differs from every prior measurement. Blockscout verification settings
  change (optimizer enabled, 200 runs). No consumer repo changes — no ABI moved.
