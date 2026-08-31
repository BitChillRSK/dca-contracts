# R42 — Multi-handler swapper purchases (one tx, many handlers' batches)

Status: **implemented** · GitHub [#101](https://github.com/BitChillRSK/dca-contracts/pull/101) · Assigned: yes · Optional/further-review: no

PR 46 of the relaunch stack originally shipped the standalone `SwapperBatcher` in GitHub
[#98](https://github.com/BitChillRSK/dca-contracts/pull/98), stacked on R38 (PR 45). After R9 and
R10 completed the ordered stack, the grouped entry point was re-evaluated against the final
`DcaManager` bytecode and measured hot path. The follow-up stacks on R10 (PR 48) and replaces the
standalone contract with an integrated `DcaManager.batchBuyRbtcAcrossHandlers` entry point in GitHub
[#101](https://github.com/BitChillRSK/dca-contracts/pull/101). Cutover:
[swapper-bot#6](https://github.com/BitChillRSK/swapper-bot/issues/6),
[front-end#22](https://github.com/BitChillRSK/front-end/issues/22), and
[bitchill-monitoring#10](https://github.com/BitChillRSK/bitchill-monitoring/issues/10).

## Objective

Let one allowlisted swapper call drive several handlers' purchase batches atomically while paying
the allowlist and cross-contract overhead only once for the whole bundle.

## Background

`batchBuyRbtc` requires every row to share one `token` and one `routeIndex`. A production tick can
therefore need several calls for idle, LayerBank, Sovryn, USDRIF, and USDT0 routes.

The original R42 design put the outer loop in a replaceable contract. That preserved manager
bytecode headroom, but each group crossed back into `DcaManager` and repeated
`OperationsAdmin.isSwapper`. The final manager is not planned to grow further, so unused bytecode
headroom has no runtime value. A like-for-like measurement on the completed stack measured
the same two-group mocked MoC purchase at 361,133 gas through `SwapperBatcher`, 347,186 gas
through a two-pass CEI-clean integrated implementation, and 344,723 gas through the one-loop
helper this PR ships. Decided 2026-08-29: ship the cheaper one-loop. Handlers are BitChill-deployed
and purchase paths stay `onlySwapper`, so bundle-wide CEI is not worth 2,463 gas on every tick
(16,410 gas / 4.5% cheaper than the standalone batcher). Default-profile (no-IR) runtime, the
R9/R50 convention, is 23,683 bytes (the two-pass version was 23,833; the one-loop six-argument
one-handler ABI was 23,716). `[profile.deploy]` (`via_ir`) is ~11,008, so EIP-170 is not a
binding constraint on that profile. The recurring protocol-paid saving outweighs preserving
unused no-IR margin.

**Atomicity.** One revert rolls back every venue in the bundle. A paused row, malformed group, or
handler failure therefore reverts the entire call. The bot filters rows off-chain and its EOA stays
allowlisted so it can retry one handler through `batchBuyRbtc` after a grouped call fails.

Decided 2026-08-29: integrate the grouped entry point in `DcaManager`; remove the standalone
batcher, its interface, and its deploy add-on. The integrated selector is `batchBuyRbtcAcrossHandlers`
(`Batch[]` of one handler's purchase batches), not the standalone's `batchBuyRbtcGroups`.

## Open product decisions

**none** — calls remain all-or-nothing, the bot EOA remains allowlisted, and the one-handler
entry point remains available as `batchBuyRbtc(Batch)` (same type as each AcrossHandlers element).

## Scope

- [x] Add `IDcaManager.Batch`, one handler's purchase batch containing token, route, and the parallel
  buyer/index/id/amount arrays.
- [x] Collapse `batchBuyRbtc` to `batchBuyRbtc(Batch calldata)` so both purchase entries share that type.
  `IPurchaseRbtc.batchBuyRbtc` stays the three-array handler ABI.
- [x] Add swapper-only `DcaManager.batchBuyRbtcAcrossHandlers(Batch[] calldata)`. Empty top-level input
  reverts `DcaManager__EmptyHandlerBatches`; each batch keeps the existing empty/length/amount/route/schedule checks.
- [x] Extract `batchBuyRbtc` into a private `_batchBuyRbtc` helper. The multi-handler entry point
  authenticates only once and loops that helper so each handler's batch finishes its checks, effects, and
  handler call before the next. A two-pass (all effects, then all interactions) was measured
  2,463 gas more expensive and was rejected: handlers are BitChill-deployed.
- [x] Remove `SwapperBatcher`, `ISwapperBatcher`, and `DeploySwapperBatcher`.
- [x] Adapt the R42 tests to call `DcaManager` directly and preserve the two-handler success,
  second-handler rollback, paused-row rollback, access-control, empty-input, and direct-retry cases.
- [x] Record final runtime size and a like-for-like gas comparison.
- [x] Update the swapper-bot cutover issue. Because this changes the final `DcaManager` ABI after
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
- the R42 unit test, renamed `DcaManagerBatchHandlersTest`
- `test/utils/BatchBuyOne.sol` (packs the former six arguments into `Batch`)
- `AGENTS.md`, this spec, `IMPLEMENTATION_ORDER.md`, and relaunch `README.md`

## Required tests

Targeted grouped-purchase tests, then the complete repository gates from `AGENTS.md`.

- One DcaManager call, two handlers: both purchase.
- A second-handler error rolls back the first handler’s balance, timestamp, and accumulated rBTC.
- A paused schedule in the second handler's batch rolls back the first.
- Empty top-level batches revert with the new DcaManager error.
- A non-swapper cannot call either purchase entry point.
- The bot EOA can still call one-handler `batchBuyRbtc` for retries.
- Fork: no new assertions; both required fork lanes still pass.

## Success criteria

- [x] One allowlist check drives every handler's purchase batch in one transaction.
- [x] `batchBuyRbtc` takes `Batch calldata`; checks, effects, and the handler call are unchanged.
  The former six-argument selector (`0x31a1a62c`) is gone.
- [x] Failure policy remains atomic and tested.
- [x] Default-profile (no-IR) runtime recorded; `[profile.deploy]` is ~11k and is not the
  profile these numbers use.
- [x] The standalone contract and its deployment/allowlist operations are gone.
- [x] Consumer follow-ups describe the final manager selector and remove the batcher deployment.
- [x] No open product decisions.

## Reviewer checklist

- [x] The one-handler helper preserves the former `batchBuyRbtc` checks/effects/handler call.
- [x] `onlySwapper` runs once per external entry, not once per inner handler.
- [x] Tests cover success, rollback, pause, malformed input, handler failure, and unauthorized callers.
- [x] Runtime and gas measurements use the default (no-IR) profile that R9/R50 track, not
  `[profile.deploy]`.
- [x] Files beyond the list above are named and justified in the PR.
- [x] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: `batchBuyRbtc` is `batchBuyRbtc((address[],address,uint256[],uint64[],uint256[],uint256))`
  (`0x3680c8da`). `DcaManager` also gains
  `batchBuyRbtcAcrossHandlers((address[],address,uint256[],uint64[],uint256[],uint256)[])`
  (`0xc8e26a20`) and `DcaManager__EmptyHandlerBatches()`. The former six-argument `batchBuyRbtc`
  (`0x31a1a62c`) is gone. The standalone used `batchBuyRbtcGroups`; that name does not ship.
- Deploy: no batcher deployment and no contract-address `addSwapper`; the bot EOA calls
  `DcaManager` directly.
- Cutover: swapper-bot updates its grouped call target and ABI. Frontend and monitoring regenerate
  the final manager ABI as required by the consumer policy; no user flow changes.
