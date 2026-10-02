LayerBank aToken handler (lending index 1). `LayerBankHandler` supplies and withdraws through the live Aave-v3-style Pool. Per-user virtual balances store **scaled** aToken amounts (`scaledBalanceOf`), not rebasing `balanceOf`.

- DOC + MoC: `LayerBankDocHandlerMoc`
- USDRIF + Uniswap and USDT0 + Uniswap: two deployments of `LayerBankHandlerDex` (same contract type with token-specific immutables; USDT0 constructor fees and `DcaManager.setTokenMinPurchaseAmount` are 6-decimal)

Deploy DOC + MoC with `script/DeployLayerBankHandler.s.sol`. Deploy the dex stables with `script/DeployUsdrifHandler.s.sol` (keyed off `STABLECOIN_TYPE`) or `script/DeployDexSwaps.s.sol`. Anvil deploys Pool/aToken mocks. Live aToken addresses are in `script/Constants.sol`.

USDT0 add-on on mainnet: the Foundry EOA cannot `assignHandler` (Safe owns `OperationsAdmin`). The Safe must `setTokenMinPurchaseAmount(usdt0, 25e6)` **before** `assignHandler` — there is no protocol-wide default; an unset min makes create revert. See root README "Ownership after deploy".

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
- Snapshotting `i_pool` from `aToken.POOL()` matches the Aave aToken's immutable Pool. A Pool migration means a new aToken and therefore a new handler. `LendingHandler` is initialized with hardcoded `EXCHANGE_RATE_DECIMALS` (RAY, `1e27`); there is no `exchangeRateDecimals` constructor arg.
- Live `withdraw` burns scaled aTokens with half-up `rayDiv` (re-measured 2026-10-02, Pool `POOL_REVISION()` 7, 16 withdrawals of which several separate half-up from round-up). `LayerBankHandler._protocolRedeem` depends on that: see **Burn rounding** below.
- Live `withdraw` reverts on insufficient aToken cash rather than under-paying. ~56,907 DOC cash vs ~199,584 supplied (2026-08-24): an illiquid reserve aborts the entire `batchBuyRbtc`, not one buyer. Same shape as Tropykus/Sovryn; ops note for PR 16.

## Burn rounding (assumption and monitoring)

The Pool has no share-sized withdraw, so the handler picks the underlying amount `a` whose burn is exactly the `s` scaled shares debited from the user's book: `floor(s × index / RAY)`, plus one wei when half-up `rayDiv` of that floor lands on `s − 1`. `LendingHandler` then requires `scaledBalanceOf` to fall by exactly `s`.

Upstream Aave v3 now burns with a ceiling (`TokenMath.getATokenBurnScaledAmount` uses `rayDivCeil`; mints floor). Under that rule the floor is always exact for `index ≥ RAY` and the `+ 1` case burns `s + 1`, which reverts `LendingHandler__ShareConsumptionMismatch`. The sizing cannot be made correct under both rules with one withdrawal: half-up needs `a × RAY / index ∈ [s − ½, s + ½)`, round-up needs `(s − 1, s]`, and the overlap `[s − ½, s]` is narrower than one wei of `a` whenever `index < 2 RAY` — which is where a live index sits. Whenever the floor lands below `s − ½`, half-up needs `floor + 1` and round-up needs `floor`. The rounding-agnostic alternative (withdraw the floor, read `scaledBalanceOf`, withdraw one more wei if one share short) costs an extra aToken read on every redeem and a second Pool `withdraw` on roughly half of them, on the swapper-paid purchase path, to cover an upgrade that fails closed. It was declined; the exact-consumption check is unchanged.

If LayerBank upgrades to round-up burns:

- Effect: every redeem whose floor needs the `+ 1` reverts — batch purchases, principal withdrawals and interest withdrawals on all three LayerBank handlers. The same redeem can succeed at a later index. Nothing is orphaned or mispriced; shares stay on the books and in the aToken.
- Detection: `test_livePool_withdrawBurnsHalfUpScaledShares` in `test/unit/layerbank/LayerBankLivePoolProbe.t.sol` fails. It runs in `make fork-layerbank` and `make fork-sovryn` at the chain tip. Monitoring should also alert on `LendingHandler__ShareConsumptionMismatch` from a LayerBank handler and on an implementation change of the Pool (`0x526D…72E9`) or aToken proxies; rerun the fork lane on either.
- Response: handlers are immutable. Deploy a handler with round-up sizing (drop the `+ 1`) on a new route index and have users exit and re-enter; until then exits may need retries across index updates.
