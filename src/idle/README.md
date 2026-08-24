Idle DOC handler (lending index 0). Deposits stay on the handler; no lending token is minted. Buys and withdrawals spend idle DOC. Interest calls revert because index 0 has no protocol name.

Deploy with `script/DeployIdleHandler.s.sol` against an existing `OperationsAdmin` + `DcaManager` (same add-on shape as `DeployUsdrifHandler`). Wiring into `DeployMocSwaps` / the CI index map is a later PR.
