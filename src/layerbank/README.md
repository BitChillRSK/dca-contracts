LayerBank aToken handler (lending index 1). `LayerBankErc20Handler` supplies and withdraws through the live Aave-v3-style Pool. Per-user virtual balances store **scaled** aToken amounts (`scaledBalanceOf`), not rebasing `balanceOf`. DOC + MoC only this relaunch.

Deploy with `script/DeployLayerBankHandler.s.sol` against an existing `OperationsAdmin` + `DcaManager` (same add-on shape as `DeployIdleHandler`). Anvil deploys Pool/aToken mocks. Wiring into `DeployMocSwaps` / the CI index map, and live Pool/aToken addresses, is a later PR.

External LayerBank incentives (LAB / Merkl) are not claimed. Native aToken interest is the only yield this handler distributes.

## Verified against live LayerBank (Rootstock, 2026-08-24)

The v2-contracts README Core listing is stale and never included DOC. Do not call v2 Core `0xc30991623fb2a63E6e1B59A29987E1EEE57447bF` (`allMarkets()` is still lRBTC / lRIF / lUSDCe / lUSDT / lWETH). Live DOC is on:

| | Address |
| --- | --- |
| aToken (lRooDOC, `ATokenInstance`) | [`0x3F04280C66314b78E9712A41BF8C1A214460cAa2`](https://rootstock.blockscout.com/address/0x3F04280C66314b78E9712A41BF8C1A214460cAa2) |
| Pool | [`0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9`](https://rootstock.blockscout.com/address/0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9) |
| Underlying (DOC) | `0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db` |
| `ADDRESSES_PROVIDER` | `0x0c32000a7d7d4454a3CC3B700a8b12678ade7052` |

- aToken exposes `POOL()`, `UNDERLYING_ASSET_ADDRESS()`, `scaledBalanceOf`. No `core()`, `accruedExchangeRate()`, or `underlying()`.
- Pool `supply` has no return. `withdraw(asset, amount, to)` returns an amount — the handler measures DOC `balanceOf` deltas instead. `getReserveNormalizedIncome` is RAY (`1e27`).
- Snapshotting `i_pool` from `aToken.POOL()` matches the Aave aToken's immutable Pool. A Pool migration means a new aToken and therefore a new handler. `TokenLending` is initialized with hardcoded RAY (`1e27`); there is no `exchangeRateDecimals` constructor arg.
- Live `withdraw` reverts on insufficient aToken cash rather than under-paying. ~56,907 DOC cash vs ~199,584 supplied (2026-08-24): an illiquid reserve aborts the entire `batchBuyRbtc`, not one buyer. Same shape as Tropykus/Sovryn; ops note for PR 16.
