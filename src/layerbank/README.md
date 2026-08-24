LayerBank lToken handler (lending index 1). `LayerBankErc20Handler` supplies and redeems through Core (`LToken` methods are `onlyCore`). Per-user virtual lToken balances live on the handler. DOC + MoC only this relaunch.

Deploy with `script/DeployLayerBankHandler.s.sol` against an existing `OperationsAdmin` + `DcaManager` (same add-on shape as `DeployIdleHandler`). Anvil deploys Core/lToken mocks. Wiring into `DeployMocSwaps` / the CI index map, and live lDOC addresses if LayerBank lists DOC, is a later PR.

External LayerBank incentives (LAB / Merkl) are not claimed. Native lToken interest is the only yield this handler distributes.

## Verified against live LayerBank

Provenance (Rootstock, Blockscout `getsourcecode`): Core `0xc30991623fb2a63E6e1B59A29987E1EEE57447bF`; LToken `0x30d6a5CFE5EA4B32123b961eBF1168940E2131A3` (`contract LToken is Market`, Solidity `^0.6.12`).

- `Market.setCore` is one-shot (`require(address(core) == address(0))`), so snapshotting `i_core` as immutable is correct. A Core migration means a new lToken and therefore a new handler.
- `Market.exchangeRate()` already folds pending interest via `pendingAccrueSnapshot()`. `accruedExchangeRate()` is the `accrue` modifier plus `return exchangeRate()`, i.e. the same number. This is not Compound's `exchangeRateStored`, so the mock aliasing them is faithful.
- `_redeem` reverts on insufficient cash (`getCash() >= uAmountIn`) instead of paying a partial amount.
