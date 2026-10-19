# Implementer 7A hand-off: hooks 7B must call

All of these live in `test/fizz/Base.sol`. Call each one after the external call has succeeded.

- `_ghostDonateStable(address h, uint256 amount)`: in `env_donateStablecoin`.
- `_ghostDonateEth(address h, uint256 amount)`: in `env_donateETH`.
- `_ghostSovrynPriceMoved(uint256 oldPrice, uint256 newPrice)`: in `env_moveSovrynPrice` and every in-scenario `setTokenPrice`.
- `_ghostSwapperSetChanged()`: after add or revoke in `operationsAdmin_secondary`.
- `_ghostAddShareSlack(address a, address h, uint256 ops)`: on every lending share operation, with the counts in plan §6. If this isn't wired, GL-10 fails, because a lending create leaves a 1-wei gap.
- `_ghostBatchRows(address h, uint256 rows)`: once per handler in each successful batch or across-handlers call.
- `_ghostBuy(address token, uint64 id)`: for each bought row.
- `_ghostPeriodEdit(address token, uint64 id)`: after a successful `updatePurchasePeriod`.
- `_ghostWindowActivated()`: after a successful activation. Until this is wired, GL-18 is skipped.
- `_ghostWindowBatch(address token, uint64 id, uint256 debit)` and `_ghostWindowShareBurn(address a, address h, uint256 burn)`: for batches inside a live window. Apply both before any inline `_checkWindowFreeze()`, which holds GL-18's check.
- `_ghostLendingDeposit(address h)`: after SP-05 on a lending create or deposit.

Other requirements:
- Every create and delete goes through `_trackSchedule` / `_untrackSchedule`, with `ghosts.maxIdSeen` read before tracking.
- No `vm.deal` after setup (GL-12).
- No DOC or USDRIF minted to addresses outside `_sumKnownHolders` (GL-13).

What else 7A built:
- `ReentrantActor` is deployed as `actors[2]`. It is inert until `arm(mode, target, data)` and goes back to inert on `disarm()`.
- `FizzFeeProbe` is deployed as `feeProbe` with `calc(uint256[])`, owned by admin.
- `_rawAccRbtc(a, h)` reads `s_accumulatedRbtc` from slot 4 on idle leaves and slot 5 on lending leaves.
- `_captureBatchCtx(IDcaManager.Batch[] memory)` records at most 8 batches and 32 rows per batch, and sets `batchCtx.truncated` when a call goes over. `_beforeSchedIndex(token, id)` looks up `stateBefore`.
- `Actor.receive()` is now `virtual`. `FoundryTester.test_globalsHold` was added.

Gas with 60 tracked schedules:

| Operation | First call | Later calls |
|---|---|---|
| `snapshotBefore` | 9.2M | 1.27M |
| `snapshotAfter` | — | 1.35M |
| `_ghostWindowActivated` | — | 1.1M |

Medusa allows 12.5M per transaction.
