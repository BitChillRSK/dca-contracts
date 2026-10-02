# Idle handlers

Route index 0, class idle. Deposits stay on the handler as the stablecoin itself: nothing is lent and
no shares are minted. Purchases and withdrawals spend that pooled balance. Interest calls revert
because the route is not lending.

- DOC, purchased through Money on Chain: `IdleDocHandlerMoc`
- USDRIF and USDT0, purchased through Uniswap V3: two deployments of `IdleHandlerDex`

An idle handler keeps no per-user book. Each schedule's `tokenBalance` in `DcaManager` is the
liability, and the handler's balance is the pooled cover for all of them. `IdleHandler`'s header
states what that relies on.

`DeployFinal` deploys all three. For the test lanes, `DeployMocSwaps` and `DeployDexSwaps` build the
handler for their own stack, and `DeployIdleHandler` adds `IdleDocHandlerMoc` to an existing
`OperationsAdmin` and `DcaManager`.
