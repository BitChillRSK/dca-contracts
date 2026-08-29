# R42 — Grouped swapper purchases (one tx, many `batchBuyRbtc` groups)

Status: **implemented; follow-up PR pending** · Assigned: yes · Optional/further-review: no

PR 46 of the relaunch stack originally shipped the standalone `SwapperBatcher` in GitHub
[#98](https://github.com/BitChillRSK/dca-contracts/pull/98), stacked on R38 (PR 45). After R9 and
R10 completed the ordered stack, the grouped entry point was re-evaluated against the final
`DcaManager` bytecode and measured hot path. The follow-up stacks on R10 (PR 48) and replaces the
standalone contract with an integrated `DcaManager.batchBuyRbtcGroups` entry point. Cutover:
[swapper-bot#6](https://github.com/BitChillRSK/swapper-bot/issues/6).

## Objective

Let one allowlisted swapper call drive several token×route purchase groups atomically while paying
the allowlist and cross-contract overhead only once for the whole bundle.

## Background

`batchBuyRbtc` requires every row to share one `token` and one `routeIndex`. A production tick can
therefore need several calls for idle, LayerBank, Sovryn, USDRIF, and USDT0 routes.

The original R42 design put the outer loop in a replaceable contract. That preserved manager
bytecode headroom, but each group crossed back into `DcaManager` and repeated
`OperationsAdmin.isSwapper`. The final manager is not planned to grow further, so unused bytecode
headroom has no runtime value. A final deploy-profile measurement on the completed stack measured
the same two-group mocked MoC purchase at 361,133 gas through `SwapperBatcher` and 347,186 gas
through the globally CEI-clean integrated implementation: 13,947 gas saved (3.9%). Runtime grew
from 22,647 to 23,833 bytes, leaving 743 bytes below EIP-170. The recurring protocol-paid saving
outweighs preserving that unused margin.

**Atomicity.** One revert rolls back every venue in the bundle. A paused row, malformed group, or
handler failure therefore reverts the entire call. The bot filters rows off-chain and its EOA stays
allowlisted so it can retry one handler through `batchBuyRbtc` after a grouped call fails.

Decided 2026-08-29: integrate the grouped entry point in `DcaManager`; remove the standalone
batcher, its interface, and its deploy add-on.

## Open product decisions

**none** — calls remain all-or-nothing, the bot EOA remains allowlisted, and the existing
single-group selector remains available.

## Scope

- [x] Add `IDcaManager.Batch`, one argument group containing token, route, and the parallel
  buyer/index/id/amount arrays.
- [x] Add swapper-only `DcaManager.batchBuyRbtcGroups(Batch[] calldata)`. Empty top-level input
  reverts; each group keeps the existing empty/length/amount/route/schedule checks.
- [x] Extract the checks/effects and interaction halves of `batchBuyRbtc` into calldata helpers.
  The grouped entry point authenticates only once and runs all effects before any interaction.
- [x] Remove `SwapperBatcher`, `ISwapperBatcher`, and `DeploySwapperBatcher`.
- [x] Adapt the R42 tests to call `DcaManager` directly and preserve the two-handler success,
  second-group rollback, paused-row rollback, access-control, empty-input, and direct-retry cases.
- [x] Record final runtime size and a like-for-like gas comparison.
- [ ] Update the swapper-bot cutover issue. Because this changes the final `DcaManager` ABI after
  R9/R10, also create or update the required frontend and monitoring ABI follow-ups.

## Out of scope

- [ ] General-purpose `multicall` or `delegatecall`.
- [ ] Changing `batchBuyRbtc` to accept mixed tokens or routes.
- [ ] Making `batchBuyRbtc` public and re-running `onlySwapper` for every internal group.
- [ ] Partial success, `try/catch`, or per-group failure events.
- [ ] Removing the bot EOA from the allowlist.
- [ ] `--broadcast`.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- removal of `src/SwapperBatcher.sol` and `src/interfaces/ISwapperBatcher.sol`
- removal of `script/DeploySwapperBatcher.s.sol`
- the R42 unit test, renamed for the integrated surface
- `AGENTS.md`, this spec, `IMPLEMENTATION_ORDER.md`, and relaunch `README.md`

## Required tests

Targeted grouped-purchase tests, then the complete repository gates from `AGENTS.md`.

- One DcaManager call, two groups, two handlers: both purchase.
- A second-group error rolls back the first group’s balance, timestamp, and accumulated rBTC.
- A paused schedule in the second group rolls back the first.
- Empty top-level groups revert with the new DcaManager error.
- A non-swapper cannot call either purchase entry point.
- The bot EOA can still call the original `batchBuyRbtc` entry point for one-handler retries.
- Fork: no new assertions; both required fork lanes still pass.

## Success criteria

- [x] One allowlist check drives every purchase group in one transaction.
- [x] The original `batchBuyRbtc` selector and behavior stay unchanged.
- [x] Failure policy remains atomic and tested.
- [x] The integrated manager remains below EIP-170 in the deploy profile.
- [x] The standalone contract and its deployment/allowlist operations are gone.
- [ ] Consumer follow-ups describe the final manager selector and remove the batcher deployment.
- [x] No open product decisions.

## Reviewer checklist

- [x] The two helpers preserve the former single-group checks/effects/handler call.
- [x] `onlySwapper` runs once per external entry, not once per inner group.
- [x] Tests cover success, rollback, pause, malformed input, handler failure, and unauthorized callers.
- [x] Runtime and gas measurements use the pinned deploy profile.
- [ ] Files beyond the list above are named and justified in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: `DcaManager` gains `batchBuyRbtcGroups((address[],address,uint256[],uint64[],uint256[],uint256)[])`
  and an empty-groups custom error. The original `batchBuyRbtc` selector is unchanged.
- Deploy: no batcher deployment and no contract-address `addSwapper`; the bot EOA calls
  `DcaManager` directly.
- Cutover: swapper-bot updates its grouped call target and ABI. Frontend and monitoring regenerate
  the final manager ABI as required by the consumer policy; no user flow changes.
