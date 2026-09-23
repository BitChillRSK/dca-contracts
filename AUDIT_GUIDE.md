# Security review guide

This document is a navigation aid, not a security claim. Review and deployment must use the exact
commit or release tag supplied for the engagement; the contracts are immutable and the repository's
main branch or open pull requests may move independently.

## Production scope

The canonical deployment is `DeployFinal` under `FOUNDRY_PROFILE=deploy`. It creates one
`OperationsAdmin`, one `DcaManager`, and seven handler instances:

| Stablecoin | Route 0 (idle) | Route 1 (LayerBank) | Route 2 (Sovryn) | Purchase venue |
|---|---|---|---|---|
| DOC | `IdleDocHandlerMoc` | `LayerBankDocHandlerMoc` | `SovrynDocHandlerMoc` | Money on Chain |
| USDRIF | `IdleErc20HandlerDex` | `LayerBankErc20HandlerDex` | — | Uniswap V3 |
| USDT0 | `IdleErc20HandlerDex` | `LayerBankErc20HandlerDex` | — | Uniswap V3 |

`src/tropykus-legacy/` is retained for local and pinned-fork adapter coverage. No live deployment
script constructs or registers it, and route index 4 is intentionally unused. Lane and add-on scripts
support tests or later deployments; `script/DeployFinal.s.sol` is the one-shot production path.

Review these as part of the deployment boundary:

- `src/`: first-party contracts and interfaces.
- `script/DeployFinal.s.sol`, `script/DeployBase.s.sol`, helper configs, and `script/Constants.sol`:
  constructor inputs, addresses, route map, and initial economic/security settings.
- `foundry.toml`, `.gitmodules`, and the recorded submodule commits: the compiler and dependency artifact.
- `test/unit/deployment/FinalDeploymentTest.t.sol`: canonical wiring assertions.

The shipped artifact uses Solidity 0.8.36, EVM `cancun`, optimizer runs 200, and `via_ir = true`.
Two test-only contracts use legacy codegen because of documented compiler stack/immutable issues;
all production contracts compile under the deploy profile's IR pipeline.

## Asset and call flow

Users call `DcaManager`, but it never holds user stablecoin or purchased rBTC. A schedule is a ledger
claim keyed by `(stablecoin, scheduleId)`. The assigned handler holds idle stablecoin or lending receipt
shares, executes the purchase, and holds each user's purchased rBTC until that user withdraws it through
`DcaManager`.

An allowlisted swapper submits batches grouped by `(stablecoin, routeIndex)`. `DcaManager` reads each
buyer's address and purchase amount from storage, applies schedule checks and debits before the handler
call, and the transaction reverts atomically if any row, handler, or output bound fails. A multi-handler
batch is also atomic across all handlers.

DOC is redeemed through Money on Chain. USDRIF and USDT0 are swapped to WRBTC through an allowlisted
Uniswap V3 path and then unwrapped only when the user withdraws. The Uniswap path checks both an
oracle-derived floor and the swapper's batch `minRbtcOut`; the stricter bound wins. Across both venues,
a successful purchase must consume exactly the net stablecoin supplied to it. Uniswap additionally
requires every intermediate-token balance on the shared router to return to its pre-swap value.

## Authority and trust boundaries

| Actor | Can | Cannot |
|---|---|---|
| Governance owner (intended Safe) | Configure manager limits; register new route indexes; assign each token-route handler once; pause deposits per pair; manage swappers; configure each handler's fees and Dex safety settings | Replace an assigned handler, reclassify a route, migrate or rescue user funds, renounce ownership |
| Swapper | Activate the five-block protected window; execute due batches; switch a Dex handler among paths governance already allowlisted | Add a path, change fees/oracle/floors, withdraw user funds, redirect a row's buyer or amount |
| Schedule owner | Fund and manage their schedules; withdraw their stablecoin, interest, and accumulated rBTC | Address another user's schedule through a mutator |
| External protocols and listed tokens | Provide custody, redemption, exchange rates, prices, and swaps used by handlers | — |

The swapper is trusted for liveness and batch selection. It may omit a due schedule, submit a zero
caller minimum, or choose any governance-allowlisted Dex path. It is not trusted for custody: the
schedule supplies the buyer and amount, and the handler's oracle floor remains when `minRbtcOut` is
zero. Governance is a configuration trust boundary. Add-only handler assignment limits a bad future
configuration to newly registered pairs/routes, but a malicious or misconfigured owner can still make
unsafe fee, oracle, floor, path, or listing decisions within the explicit setter bounds.

All nine ownable deployments are constructed under the broadcaster EOA, configured, and then propose
the Safe as pending owner. The Safe must accept each one. Until acceptance, the broadcaster remains
owner; afterward, ownership is independent per contract and configuration can diverge unless operations
apply the same decision everywhere it is meant to apply.

## Accounting properties worth checking

- Deposits credit only the handler's measured balance increase and require it to equal the request;
  fee-on-transfer tokens are unsupported.
- Idle handlers keep per-user balances. Lending handlers keep per-user virtual shares and clamp a
  withdrawal to that user's share-backed position.
- Every successful lending redemption must reduce the handler's external receipt-share balance by
  exactly the virtual shares debited. Cash may be lower only when the complete claim was consumed by
  a venue fee or realized loss.
- Integrator return values and balance views are not treated as received cash. Stablecoin and native
  receipts are measured by balance deltas.
- Every successful purchase must reduce the handler's stablecoin balance by exactly the net amount
  passed to the venue. A positive rBTC/WRBTC receipt with a partial or excessive input delta reverts
  the entire batch.
- Purchase fees are computed per row, transferred before the venue call, and configured independently
  on every handler. Batch rBTC and measured stablecoin are allocated using planned net amounts as
  weights. Integer division can leave less than one wei per row uncredited in the handler.
- Schedule principal is the amount still authorized for purchases, not a mark-to-market claim on a
  lending position. A full receipt-share claim may redeem for less stablecoin after an external loss or
  fee; the shortfall is not restored to principal.
- Accumulated rBTC is payable only to the recorded user through `DcaManager`; there is no owner rescue
  or arbitrary recipient parameter.

## Scheduling and failure semantics

Purchase periods are whole numbers of UTC days and at least the configured minimum. Before the first
successful purchase, `cadenceAnchor` is zero; that purchase establishes the cadence at the current UTC
midnight. Later eligibility is measured from that grid.

A successful purchase consumes the newest due slot and all earlier missed slots. Missed purchases are
not caught up: funds remain in the schedule and its lifetime extends. An established weekly Monday
schedule that fails Monday and succeeds Tuesday is next due the following Monday. A schedule cannot
purchase twice in one UTC day, even after a long gap. All transactions included within a due UTC day
are equivalent for cadence; a later retry changes only execution price and external market state.

The protected purchase window blocks only schedule edits/deletion and stablecoin/interest withdrawals
through activation block `N + 4`; those actions resume at `N + 5`. Creation, deposits, interest top-up,
rBTC withdrawal, reads, governance, and purchases remain open. Purchases do not require a live window.

Other deliberate availability trade-offs:

- A bad row reverts its entire handler batch; a bad handler batch reverts an across-handlers call.
- A user pause blocks purchases only. A governance deposit pause blocks new inflows only, preserving
  purchases and exits.
- Contracts are not proxies. Recovery from a defective immutable handler is a new route index plus
  manual user exit/re-entry, not an in-place upgrade or owner migration.

## External assumptions and unsupported cases

- Listed stablecoins, Money on Chain, lending markets, the Uniswap router/pools, WRBTC, and the MoC
  BTC/USD oracle remain correct and available. External illiquidity or pauses can revert purchases or
  withdrawals.
- Dex pricing assumes the input stablecoin is worth one USD; there is no stablecoin/USD oracle. A
  depeg beyond the configured BTC/USD-derived floor stops swaps rather than repricing the asset.
- Dex input tokens must have at most 18 decimals. Fee-on-transfer tokens and asynchronous or partial
  lending redemptions are unsupported.
- The bot must quote, simulate, group rows by handler, respect the protected-window workflow, and retry
  within the due UTC day when appropriate. Monitoring must track custom errors and the current event
  ABI. There is no `CadenceAnchorUpdated` log: after a purchase, recompute the anchor from prior
  schedule state or read `getDcaSchedule`; use `PurchaseRbtc__RbtcBought` as the purchase signal.

## Reproducing the release gates

```bash
git submodule update --init --recursive
make check
make check-deploy
make fork-sovryn
make fork-tropykus
make fork-dex-path
make slither
make aderyn
```

Fork commands require `RSK_MAINNET_RPC_URL`. `make check-deploy` is intentionally separate and slow:
it runs the suite against the `via_ir` bytecode intended for deployment. Slither retains triaged
findings and exits non-zero; the current classification is in
`docs/relaunch/R73-RELEASE_RECORD.md`. The fork suite runs on Anvil/revm against live state and is not
a Rootstock consensus/compiler proof.

For test organization and exact lane semantics, read `AGENTS.md`. For deployment sequencing, read
`docs/relaunch/CUTOVER_RUNBOOK.md`. Historical design specs under `docs/relaunch/` explain why a choice
was made, but this guide and the verified source state the current protocol without requiring that
history.

## Required before mainnet

- Complete the independent security review against a frozen commit and resolve or explicitly accept
  every finding.
- Approve the launch economic matrix (fees, per-token minimum purchase amounts, and minimum period)
  and make the deploy constants match it. Fee changes affect later purchases immediately; manager
  minimum changes constrain future creates/updates but do not rewrite existing schedules.
- Deploy and verify a representative `FOUNDRY_PROFILE=deploy` (`via_ir = true`) artifact on Rootstock
  testnet. This exact-profile Blockscout proof remains outstanding.
- Merge the stacked pull requests in order, freeze/tag the resulting commit, and rerun every release
  gate above on that exact commit.
- Execute the cutover runbook: verify addresses and wiring, have the Safe accept every ownership,
  update all five consumers, simulate, and only then enable bot ticks.
