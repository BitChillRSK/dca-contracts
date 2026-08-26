# R22 — Deploy scripts, constants, harness, and CI matrix

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 22 of R22 (reordered after R30). Stack on R30 (PR 21). Last required R22 PR; R9 follows as PR 23.

## Objective

Wire LayerBank into the live index map (idle=0, LayerBank=1, Sovryn=2), split the shared harness so lending-share assertions are protocol-specific, and make CI cover `none` / `layerbank` / `sovryn`. Also ship the **round-up solvency** regression for `_stablecoinToShares` (documented on `TokenLending`; LayerBank + Aave rayDiv is the sharpest assertion surface).

## Background

PR 15 shipped `LayerBankDocHandlerMoc` behind an add-on deploy script. PR 16 (R25) finishes redeem-helper naming, PR 17 (R26) swaps the “lending token” noun for `shares`, and PR 21 (R30) centralizes the purchase pipeline and stablecoin-source seam — build the harness split against those final names and inheritance. This PR is the cutover: constants, `DeployMocSwaps` / harness / Makefile / CI.

**Round-up solvency (required in this PR, not deferred).** `_stablecoinToShares` documents `Math.Rounding.Up` for all lending handlers (Tropykus / Sovryn / LayerBank). Aave `withdraw` burns scaled shares with `amount.rayDiv(index)` (round nearest), so LayerBank is the sharpest place to regression-test: debiting ≥ what Aave burns keeps `sum(s_aTokenBalances) <= aToken.scaledBalanceOf(handler)`. Flipping TokenLending to round **down** would let virtual books drift above reality; happy-path suites still pass. Ship a test that fails under round-down sizing — do not leave this as a handler comment.

Related: [R22-layerbank-handler.md](./R22-layerbank-handler.md), [R25-lending-redeem-naming.md](./R25-lending-redeem-naming.md), [R22-idle-handler.md](./R22-idle-handler.md).

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 22. Implement without asking.

## Scope

- [ ] `script/Constants.sol` index map: `0` idle, `1` LayerBank, `2` Sovryn, `3` reserved for future MoC lending. Drop Tropykus from the new deploy path.
- [ ] `DeployMocSwaps` / `DeployDexSwaps` (as applicable), `MocHelperConfig` live Pool/aToken fields, register LayerBank at index 1.
- [ ] Split `DcaDappTest` / shared harness so lending-share assertions live only in lending-protocol-specific tests. `LENDING_PROTOCOL=layerbank` is a first-class lane.
- [ ] CI / Makefile: cover `none`, `layerbank`, and `sovryn` with `SWAP_TYPE=mocSwaps` (and existing dex lane policy unchanged unless this PR must touch it).
- [ ] Ops note already recorded: illiquid LayerBank DOC cash aborts whole `batchBuyRbtc` — document in PR body if not already; no new product behavior.
- [ ] **Round-up solvency regression (LayerBank):**
  - Add a dedicated test (prefer `test/ai-generated/unit/layerbank/`) that deposits, then redeems many **odd** DOC amounts under a non-`RAY` index (or fuzz), with the mock burning scaled shares via Aave-like **round-nearest** `rayDiv`.
  - After the sequence, assert `sum` of per-user `getUserShares` (or the handler’s tracked mapping exposed in the test subclass) **≤** `aToken.scaledBalanceOf(handler)`.
  - The test must be written so that replacing `_stablecoinToShares`’s `Rounding.Up` with `Rounding.Down` would fail it (document that in the test comment). Extend `MockLayerBank` if it does not yet expose nearest-rayDiv burn behavior matching live Aave.
  - Run this test in the new `layerbank` CI lane. Do not rely on ported Tropykus/Sovryn suites alone.

## Out of scope

- [ ] R25 rename work (must already be merged).
- [ ] R9 `TokenLending__UserSharesUpdated`.
- [ ] R27 Tropykus zero-mint / batch zero-received guards (must already be merged; [R27-tropykus-lending-guards.md](./R27-tropykus-lending-guards.md)).
- [ ] R28 `LendingErc20Handler` extract (must already be merged; [R28-lending-erc20-handler.md](./R28-lending-erc20-handler.md)).
- [ ] R10 full natspec rewrite.
- [ ] LayerBank Uniswap / USDRIF.
- [ ] Merkl / LAB / harvest.
- [ ] Adding `stablecoinRecipient` to LayerBank redeem (PR 15 decision: always withdraw onto the handler).
- [ ] Any `ITokenLending` event/error ABI. R25 (PR 16) already renamed the adjustment event to `TokenLending__AmountToRedeemAdjusted`; do not rename it again.
- [ ] `--broadcast` or live-chain ops.

## Files likely touched

- `script/Constants.sol`
- `script/DeployMocSwaps.s.sol` / `DeployDexSwaps.s.sol` / `MocHelperConfig` (or equivalents)
- `script/DeployLayerBankHandler.s.sol` (wire live addresses / stop being mocks-only on the main path as this PR defines)
- `test/unit/DcaDappTest.t.sol` and related harness / Makefile / CI workflow
- `test/mocks/MockLayerBank.sol` (rayDiv-nearest burn if missing)
- `test/ai-generated/unit/layerbank/*` (solvency regression + harness adaptations)
- `docs/relaunch/README.md` Status after the PR opens

## Required tests

Targeted (exact Makefile targets once the new lanes exist — document them in the PR):

```
# layerbank MoC lane (names may match make moc-layerbank / LENDING_PROTOCOL=layerbank)
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods -j 1

# dedicated solvency test (adjust --match-test to the name you ship)
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC \
  forge test --match-test test_layerbank_virtualSharesRoundUp_keepsBooksSolvent -j 1

make check   # must include the new layerbank lane once wired
make fork-sovryn
make fork-tropykus
```

Behaviors to assert:

- Index map: idle 0, LayerBank 1, Sovryn 2; Tropykus not on the new admin path.
- Shared harness green on `none` / `layerbank` / `sovryn`.
- Solvency: after odd-amount redeem sequence, virtual scaled sum ≤ handler `scaledBalanceOf`; comment states round-down would fail.

Fork: live LayerBank probe still runs on `make fork-sovryn` at tip; no new fork-only requirement beyond `AGENTS.md` before push.

## Success criteria

- [ ] Constants and deploy scripts implement the new index map; CI covers `none` / `layerbank` / `sovryn`.
- [ ] Harness no longer assumes Tropykus lending tokens on every lane.
- [ ] Round-up solvency regression exists, is named in the PR test plan, and runs on the layerbank lane.
- [ ] `make check`, `make fork-sovryn`, and `make fork-tropykus` pass.
- [ ] No unrelated refactors.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold unless this spec explicitly changes one.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none expected (wiring + tests). Confirm if any constructor arg lists change for production LayerBank.
- Scripts: yes — main deploy path and constants. Local/test may still use mocks where this PR says so; do not `--broadcast` from the agent.
- Cutover: frontend/index map switches to idle / LayerBank / Sovryn. Call out illiquid-batch revert ops note.
