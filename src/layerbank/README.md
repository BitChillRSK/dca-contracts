LayerBank aToken handler (lending index 1). `LayerBankErc20Handler` supplies and withdraws through the live Aave-v3-style Pool. Per-user virtual balances store **scaled** aToken amounts (`scaledBalanceOf`), not rebasing `balanceOf`.

- DOC + MoC: `LayerBankDocHandlerMoc`
- USDRIF + Uniswap and USDT0 + Uniswap: two deployments of `LayerBankErc20HandlerDex` (same bytecode; USDT0 constructor fees and `DcaManager.setTokenMinPurchaseAmount` are 6-decimal)

Deploy DOC + MoC with `script/DeployLayerBankHandler.s.sol`. Deploy the dex stables with `script/DeployUsdrifHandler.s.sol` (keyed off `STABLECOIN_TYPE`) or `script/DeployDexSwaps.s.sol`. Anvil deploys Pool/aToken mocks. Live aToken addresses are in `script/Constants.sol`.

USDT0 add-on on mainnet: the Foundry EOA cannot `assignTokenHandler` (Safe owns `OperationsAdmin`). The Safe must assign the handler **and** `setTokenMinPurchaseAmount(usdt0, 25e6)` — the DcaManager default is 25 ether. See root README "Ownership after deploy".

External LayerBank incentives (LAB / Merkl) are not claimed. Native aToken interest is the only yield this handler distributes.

## Verified against live LayerBank (Rootstock, 2026-08-24)

The v2-contracts README Core listing is stale and never included DOC. Do not call v2 Core `0xc30991623fb2a63E6e1B59A29987E1EEE57447bF` (`allMarkets()` is still lRBTC / lRIF / lUSDCe / lUSDT / lWETH). Live DOC is on:

| | Address |
| --- | --- |
| aToken (lRooDOC, `ATokenInstance`) | [`0x3F04280C66314b78E9712A41BF8C1A214460cAa2`](https://rootstock.blockscout.com/address/0x3F04280C66314b78E9712A41BF8C1A214460cAa2) |
| aToken (lRooUSDRIF) | [`0xc96fBD12bE56Dd565b258d243344bCf792A51128`](https://rootstock.blockscout.com/address/0xc96fBD12bE56Dd565b258d243344bCf792A51128) |
| aToken (lRooUSDT0) | [`0x6bE7d4cfCe825b106aa88F6916A412c5af230Ec0`](https://rootstock.blockscout.com/address/0x6bE7d4cfCe825b106aa88F6916A412c5af230Ec0) |
| Pool | [`0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9`](https://rootstock.blockscout.com/address/0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9) |
| Underlying (DOC) | `0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db` |
| Underlying (USDRIF) | `0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37` |
| Underlying (USDT0, 6 decimals) | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` |
| `ADDRESSES_PROVIDER` | `0x0c32000a7d7d4454a3CC3B700a8b12678ade7052` |

- aToken exposes `POOL()`, `UNDERLYING_ASSET_ADDRESS()`, `scaledBalanceOf`. No `core()`, `accruedExchangeRate()`, or `underlying()`.
- Pool `supply` has no return. `withdraw(asset, amount, to)` returns an amount — the handler measures DOC `balanceOf` deltas instead. `getReserveNormalizedIncome` is RAY (`1e27`).
- Snapshotting `i_pool` from `aToken.POOL()` matches the Aave aToken's immutable Pool. A Pool migration means a new aToken and therefore a new handler. `TokenLending` is initialized with hardcoded `EXCHANGE_RATE_DECIMALS` (RAY, `1e27`); there is no `exchangeRateDecimals` constructor arg.
- Live `withdraw` reverts on insufficient aToken cash rather than under-paying. ~56,907 DOC cash vs ~199,584 supplied (2026-08-24): an illiquid reserve aborts the entire `batchBuyRbtc`, not one buyer. Same shape as Tropykus/Sovryn; ops note for PR 16.
