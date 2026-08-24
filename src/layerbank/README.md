LayerBank lToken handler (lending index 1). `LayerBankErc20Handler` supplies and redeems through Core (`LToken` methods are `onlyCore`). Per-user virtual lToken balances live on the handler. DOC + MoC only this relaunch.

Deploy with `script/DeployLayerBankHandler.s.sol` against an existing `OperationsAdmin` + `DcaManager` (same add-on shape as `DeployIdleHandler`). Anvil deploys Core/lToken mocks. Wiring into `DeployMocSwaps` / the CI index map, and live lDOC addresses if LayerBank lists DOC, is a later PR.

External LayerBank incentives (LAB / Merkl) are not claimed. Native lToken interest is the only yield this handler distributes.
