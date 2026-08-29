Idle DOC handler (OperationsAdmin route index 0, class idle). Deposits stay on the handler; no shares are minted. Buys and withdrawals spend idle DOC. Interest calls revert because this route is not lending.

Deploy with `script/DeployIdleHandler.s.sol` against an existing `OperationsAdmin` + `DcaManager`, or through `DeployMocSwaps` which registers index 0 and assigns this handler on the live MoC map.
