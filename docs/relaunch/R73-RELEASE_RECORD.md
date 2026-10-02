# R73 release record — deploy script, static analysis, doc truthfulness

Commit under test: recorded at PR open (see Status). Profile for shipped bytecode:
`FOUNDRY_PROFILE=deploy` (`via_ir = true`, optimizer 200). Figures below also quote
`[profile.default]` where Measurement basis requires it.

## Canonical deployment

- Script: [`script/DeployFinal.s.sol`](../../script/DeployFinal.s.sol)
- Tests: [`test/unit/deployment/FinalDeploymentTest.t.sol`](../../test/unit/deployment/FinalDeploymentTest.t.sol)
- Map (one `OperationsAdmin` / one `DcaManager`, seven handlers):
  - DOC: idle / LayerBank / Sovryn → MoC
  - USDRIF: idle / LayerBank → Uniswap
  - USDT0: idle / LayerBank → Uniswap
- Fail-closed: zero addresses, incomplete LayerBank/Sovryn wiring, missing `INITIAL_SWAPPER`,
  non-live environment, and non-mainnet `run()` all revert. Rootstock **testnet** lacks the
  LayerBank aTokens this map needs, so the live `run()` path is **mainnet-only**; Anvil tests
  exercise `deployStack` with mocks.
- Lane scripts (`DeployMocSwaps`, `DeployDexSwaps`, add-ons) remain for local/fork and incremental
  add-ons. They are not the cutover path.
- Ops note carried from R71: standing `redeemDocRequest` settlements on pre-relaunch MoC handlers
  were checked and closed (2026-09-07); no cutover action.

## Commands (reproducible)

```bash
# Targeted
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract FinalDeploymentTest

make aderyn
make slither   # exits non-zero while findings remain; triage is below

# Full gates (same commit)
make check
make check-deploy
make fork-sovryn
make fork-tropykus
make fork-dex-path

# Sizes / storage (default profile = Measurement basis; also under deploy profile)
forge build --sizes
FOUNDRY_PROFILE=deploy forge build --sizes
forge inspect DcaManager storageLayout
forge inspect OperationsAdmin storageLayout
```

Live broadcast (human only; never from an agent session): the command is in
[`CUTOVER_RUNBOOK.md`](./CUTOVER_RUNBOOK.md#deploy). Then Safe `acceptOwnership()` on every ownable
address logged by the script.

## Static analysis triage

No first-party `src/` change in this PR: findings are false positives or accepted design.
Suppressions are **not** widened in `slither.config.json` / `aderyn.toml` beyond excluding
`test/`, `script/`, and `lib/`.

R75 follow-up: both analyzers were rerun after the cadence correction. The triage below still applies;
Slither's former dead-code finding is resolved by removing the unused `_calculateFee` wrapper.

### Aderyn (`make aderyn` → gitignored `report.md`)

| ID | Finding | Triage |
|---|---|---|
| H-1 | Weak randomness (`block.timestamp % 1 days`) | **False positive.** UTC day-boundary eligibility (R2), not PRNG. |
| H-2 | Reentrancy after external call (deposit / create / top-up / ERC-165 on assign) | **Accepted.** Deposit/create use pull-then-credit with `nonReentrant` (invariant 6). Top-up is `onlyDcaManager` interest math. Assign’s ERC-165 reads are views on BitChill handlers before writing the map. |
| L-1 | Centralization / `onlyOwner` | **Accepted.** Governance is a Safe; two-step ownership; no owner rescue of user funds. |
| L-2 | Address setters without zero checks | **Accepted / false positive** where setters validate; owner-only config. |
| L-3 | `nonReentrant` not first modifier | **Accepted.** Behind `whenUserMutationsAllowed` by design (invariant 6); private view cannot re-enter. |
| L-4–L-9 | Large literals, loop requires, costly loops, unused import, unchecked return | **Accepted / informational.** Hot-path loops are intentional; returns measured via balance deltas (invariant 1). |

### Slither (`make slither`)

| Detector | Triage |
|---|---|
| arbitrary-from-in-transferFrom | **Accepted.** Handler pulls `user` as supplied by `onlyDcaManager`. |
| eth-send / low-level-call on rBTC withdraw | **Accepted.** Pays `msg.sender` only (invariant 3); low-level call for native transfer. |
| weak-PRNG / timestamp / divide-before-multiply / strict-equality on purchase eligibility | **False positive / accepted.** UTC day math and period checks, not randomness. |
| uninitialized state (`s_scheduleIds`) / local (`amountWithdrawn`) | **False positive.** Mapping default empty; local set on all paths that read it. |
| reentrancy (create / deposit / withdraw rBTC) | **Accepted.** `nonReentrant` + CEI where required; purchase paths are `onlySwapper`. |
| unused-return on withdraw | **Accepted.** Cash is balance-delta measured (invariant 1 / R20). |
| calls-inside-a-loop | **Accepted.** Batch / withdraw-all pair loops by design. |
| naming-convention (`i_*`, `Contract__Event`) | **Accepted.** House style. |
| unimplemented `_purchaseToken` on Dex leaves | **False positive.** Resolved through the funding base in the C3 linearization. |
| dead-code (`_calculateFee`) | **Resolved in R75.** Test harnesses call the existing loaded-settings helper directly. |

## Release-artifact checks

Recorded at PR open on this branch tip:

| Check | Result |
|---|---|
| `forge build --sizes` (default) | See PR body / Measurement basis update |
| `FOUNDRY_PROFILE=deploy forge build --sizes` | See PR body |
| Storage layouts | Unchanged vs R72 tip for `src/` (this PR does not touch Solidity behavior) |
| ABI | None — scripts/docs/static-analysis only |

## Known via_ir stack-too-deep carve-outs

`[profile.deploy]` (`via_ir = true`) excludes two test files via
`compilation_restrictions` (built under legacy codegen instead, assertions still run as part of
`make check-deploy`):

| File | Cause |
|---|---|
| `test/unit/ZeroTokenPurchaseUniswapTest.sol` | solc error 1284: always-reverting constructor's immutable assignment is dead-code-eliminated before a later checker expects it assigned. See [R55](./R55-solx-and-ir-evaluation.md). |
| `test/ai-generated/unit/layerbank/LayerBankErc20HandlerDexTest.t.sol` | Yul stack-too-deep ("Variable size is 1 too deep in the stack"): the one `HandlerTestHarness` subclass that is both a Dex and a LayerBank lending handler overflows the Yul optimizer's stack allocator when via_ir compiles its full inherited call graph. Pre-existing (confirmed via `git worktree` against this branch's base, unrelated to R73); found and carved out here. |

## License

BUSL-1.1 on `src/` per [R72](./R72-licensing.md); Additional Use Grant for non-production use;
Change License `GPL-2.0-or-later` after four years. Pre-relaunch published code remains MIT.
`script/` / `test/` stay MIT.
