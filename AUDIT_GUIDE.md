# Security review guide

This guide states what ships, who is trusted with what, which properties the code is meant to hold,
and which risks are accepted. It is a navigation aid, not a security claim. Review the exact commit
or tag supplied for the engagement: deployed contracts are immutable, and `main` and the open pull
requests keep moving.

## Production scope

`script/DeployFinal.s.sol`, run under `FOUNDRY_PROFILE=deploy`, is the only production deployment
path. It creates one `OperationsAdmin`, one `DcaManager`, and seven handlers:

| Stablecoin | Route 0 (idle) | Route 1 (LayerBank) | Route 2 (Sovryn) | Purchase venue |
|---|---|---|---|---|
| DOC | `IdleDocHandlerMoc` | `LayerBankDocHandlerMoc` | `SovrynDocHandlerMoc` | Money on Chain |
| USDRIF | `IdleHandlerDex` | `LayerBankHandlerDex` | — | Uniswap V3 |
| USDT0 | `IdleHandlerDex` | `LayerBankHandlerDex` | — | Uniswap V3 |

In scope:

- `src/`, except `src/tropykus-legacy/`: about 1,900 lines excluding comments and blank lines
  (`cloc src --exclude-dir=tropykus-legacy`). The [README](./README.md#contracts) has the inheritance
  map. Interfaces of external protocols (`IMocProxy`, `ICoinPairPrice`, `IWRBTC`,
  `IUniswapV3SwapRouter`, `IiToken`, `ILayerBankPool`, `ILayerBankAToken`) are ABIs only.
  `SovrynHandlerDex` is built and tested but is not one of the seven handlers `DeployFinal` creates.
- `script/DeployFinal.s.sol`, `script/DeployBase.s.sol`, and `script/Constants.sol`: constructor
  inputs, external addresses, the route map, and the launch parameters. `DeployFinal` imports
  `MocHelperConfig` and `UsdrifHelperConfig` for their struct types only and fills them with its own
  mainnet values. [`ADDRESSES.md`](./ADDRESSES.md) lists the external contracts the deployment binds
  to.
- `foundry.toml` and the OpenZeppelin submodule commit: the compiler and dependency artifact.
- `test/unit/deployment/FinalDeploymentTest.t.sol`: asserts the wiring `DeployFinal` produces.

Out of scope:

- `src/tropykus-legacy/`. It is kept for local and pinned-fork coverage of a second lending adapter.
  `DeployMocSwaps` and `DeployDexSwaps` construct it on local and fork runs only: their testnet and
  mainnet branches revert on Tropykus, and `DeployFinal` never names it. Route index 4 is left unused
  so it is never reinterpreted as another venue.
- Every other deploy script. BitChill deploys production with `DeployFinal` only. That is a
  deployment decision, not something the other scripts enforce: `DeployMocSwaps` and `DeployDexSwaps`
  create their own `OperationsAdmin` and `DcaManager`, and both have testnet and mainnet branches
  that deploy production handlers. The mainnet branch proposes the Safe as owner; on testnet the
  broadcasting EOA stays owner. A stack built by one of them is a separate deployment, outside this
  review.
- The off-chain consumers (swapper bot, front end, data API, monitoring), which live in other
  repositories, and the code of the external protocols.

### Compiler and dependencies

| | |
|---|---|
| Compiler | solc 0.8.36, EVM `cancun`, optimizer on, 200 runs |
| Shipped bytecode | `[profile.deploy]`: the settings above with `via_ir = true` |
| Day-to-day and CI | `[profile.default]` and `[profile.ci]`: the same settings with `via_ir = false` |
| OpenZeppelin Contracts | v5.7.0 (`cab19933`), git submodule, unmodified |
| forge-std | vendored under `lib/forge-std`; tests and scripts only |

`make check-deploy` compiles `src/`, `test/`, and `script/` under the deploy profile and runs the
suite against the bytecode a broadcast would deploy. One test file,
`test/ai-generated/unit/layerbank/LayerBankHandlerDexTest.t.sol`, is compiled with legacy codegen
under that profile because via-IR fails on it with a Yul stack-too-deep error. No production contract
is affected.

Rootstock executes every opcode this target emits: `PUSH0` since Arrowhead (April 2024), and `MCOPY`
and transient storage since Lovell (March 2025). First-party code uses no blob opcode. `DcaManager`
inherits OpenZeppelin's `ReentrancyGuardTransient`, so transient storage is on the production path.

### Launch configuration

The values `DeployFinal` sets, from `script/Constants.sol`, and what the owner can do to each one
afterward.

| Parameter | Launch value | Owner setter and the bound the contract enforces |
|---|---|---|
| Purchase fee, per handler | 1% up to 250 tokens, then decreasing toward 0.2% ([math](./docs/PURCHASE_FEES.md)) | `setFeeRateParams`: minimum ≤ maximum ≤ 5%. The threshold is any `uint112`; at every value the rate stays between the two |
| Minimum purchase amount, per token | 25 tokens (`25e18` DOC and USDRIF, `25e6` USDT0) | `setTokenMinPurchaseAmount`: non-zero, no upper bound |
| Minimum purchase period | 7 days | `setMinPurchasePeriod`: whole UTC days, at least one |
| Schedules per user and token | 10 | `setMaxSchedulesPerToken`: any `uint16`. Zero blocks every new schedule; existing ones are unaffected |
| Dex oracle floor | 97% of the oracle-implied output | `setAmountOutMinimumPercent`: between the safety check and 100% |
| Dex floor safety check | 95% | `setAmountOutMinimumSafetyCheck`: at most the active floor |
| Protected purchase window | 5 blocks | None. It is a constant |

Dex paths at deploy: USDT0 → WRBTC through the 0.30% pool; USDRIF → USDT0 (0.05%) → WRBTC (0.30%)
active, with USDRIF → USDT (0.05%) → WRBTC (0.30%) also allowlisted on both USDRIF handlers.

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
the handler supplies the whole retrieved (gross) stablecoin to the venue, and a successful purchase must
consume exactly that amount. No stablecoin fee is withheld first: the purchase fee is a share of the
measured rBTC/WRBTC output, credited to the fee collector afterward. Uniswap additionally requires every
intermediate-token balance on the shared router to return to its pre-swap value.

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
unsafe fee, oracle, floor, path, or listing decisions within the explicit setter bounds. The Dex
safety-check bound stops a single percentage change from widening the floor; it does not cover
`setMocOracle`, which replaces the price the floor is computed from in one transaction with no bound
against the previous oracle.

**Worst case for a leaked swapper key.** The key can reopen the protected window in the block the previous
one ends, submit a zero caller minimum, and activate any allowlisted Dex path. While windows are
chained, users cannot pause, edit, delete, or withdraw stablecoin or interest. Each Dex schedule that
comes due in that time can be filled down to the oracle floor (3% below the oracle at launch settings),
once per period. MoC routes have no pool to move. Principal cannot leave to anyone but its owner, and
`revokeSwapper` ends it. This is accepted without a mandatory gap between windows: a gap would give
users a few open blocks they are unlikely to use before the Safe revokes the key, and a loose fill pays
the key holder only if they also move the pool around the batch.

All nine ownable deployments are constructed under the broadcaster EOA, configured, and then propose
the Safe as pending owner. The Safe must accept each one. Until acceptance, the broadcaster remains
owner; afterward, ownership is independent per contract and configuration can diverge unless operations
apply the same decision everywhere it is meant to apply.

Handler admission checks registry affiliation, not canonical manager identity.
An impostor manager can return the same registry from `i_operationsAdmin()`.
Before acceptance or permanent assignment, operations must verify the handler's exact immutable manager, stablecoin, and released code.
An incorrect owner assignment can disable that pair or expose tokens approved to the incorrectly bound handler.
The Safe controls later assignments; the broadcaster EOA configures the initial stack before Safe acceptance.
The [cutover runbook](./docs/relaunch/CUTOVER_RUNBOOK.md) specifies those checks.

How the boundaries are enforced:

- Handlers take deposits, withdrawals, interest calls, purchases, and rBTC claims from their immutable
  `DcaManager` only (`onlyDcaManager`). Everything else a handler accepts directly:
  - its owner's setters and `transferOwnership`, and `acceptOwnership` from the pending owner;
  - `setPurchasePath` on a Dex handler, from the owner or a swapper;
  - `restoreLendingApproval` and `restoreSwapRouterApproval` from anyone, which re-grant the allowance
    set at construction;
  - native rBTC from anyone, through an open `receive()`. Money on Chain payouts and WRBTC unwraps
    arrive that way. A purchase credits only the balance increase it measures around its own venue
    call, so rBTC sent in at any other time is credited to no one, and no function recovers it.
- Lending handlers keep a standing unlimited stablecoin allowance to their lending market, and Dex
  handlers to SwapRouter02. The spender can therefore pull any stablecoin the handler holds at any
  time, not only during a BitChill call.
- `DcaManager` has one ownership check, `_callersSchedule`. Every user call that changes an existing
  schedule reaches it through that function and takes no owner argument. The purchase path needs no
  ownership check: it reads the buyer from the schedule.
- Every external function that writes a schedule is `nonReentrant`, except `batchBuyRbtc` and
  `batchBuyRbtcAcrossHandlers`. Those are swapper-only and finish each handler's schedule writes
  before calling it. In an across-handlers call a later handler's schedules are written after earlier
  handler calls; handlers are BitChill-deployed, so this is accepted.

`AGENTS.md` lists these and the other invariants contributors must preserve, under **Protocol
invariants**, with the reason for each.

## Accounting properties worth checking

- Deposits credit only the handler's measured balance increase and require it to equal the request;
  fee-on-transfer tokens are unsupported.
- Idle handlers keep no per-user book: pooled cash is bounded by the schedule balances `DcaManager`
  debits before any outflow, plus the exact-delta checks on deposits and purchases. Lending handlers
  keep per-user virtual shares and clamp a withdrawal to that user's share-backed position.
- Every successful lending redemption must reduce the handler's external receipt-share balance by
  exactly the virtual shares debited. Cash may be lower only when the complete claim was consumed by
  a venue fee or realized loss.
- Integrator return values and balance views are not treated as received cash. Stablecoin and native
  receipts are measured by balance deltas.
- Every successful purchase must reduce the handler's stablecoin balance by exactly the gross amount
  retrieved for the batch and passed to the venue. A positive rBTC/WRBTC receipt with a partial or
  excessive input delta reverts the entire batch.
- Purchase fees are computed per row from the planned gross amounts and configured independently on
  every handler. No stablecoin moves to the collector: after the venue call, measured output `Q` is
  split over the planned gross sum `G`. Each buyer is credited `floor(Q × netᵢ / G)` and the collector
  `floor(Q × F / G)` on the same accumulated-rBTC books, where `netᵢ` is the row's amount minus its fee
  and `F` the batch fee. `minRbtcOut` and the Uniswap oracle floor bind on `Q`, before the fee share.
  The per-row `amountSpent` reported in events is the row's share of the retrieved gross. Integer
  division can leave less than one wei per row, and per fee, uncredited in the handler.
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
schedule that fails Monday and succeeds Tuesday is next due the following Monday. While its period is
unchanged, a schedule cannot purchase twice in one UTC day, even after a long gap. All transactions
included within a due UTC day are equivalent for cadence; a later retry changes only execution price
and external market state.

A period edit does not move the anchor, so the next due day is the existing anchor plus the new period.
The owner can therefore make their own schedule due again on a day it already bought: after a purchase
that landed at least one new period late, shortening the period to no more than that lateness puts
anchor-plus-period on or before today. A 28-day schedule bought seven days late and then set to seven
days is due again that same day. That second purchase re-anchors on today, so the edit yields one extra
purchase, not a loop. Only the schedule's owner can trigger it and the amount is still bounded by the
schedule balance; `updatePurchasePeriod` is blocked during a protected window like every other edit.
This is accepted, not enforced away: refusing a period that makes the schedule immediately due would
also refuse ordinary mid-cycle shortening.

The protected purchase window blocks only schedule edits/deletion and stablecoin/interest withdrawals
through activation block `N + 4`; those actions resume at `N + 5`. Creation, deposits, interest top-up,
rBTC withdrawal, reads, governance, and purchases remain open. Purchases do not require a live window.

Other deliberate availability trade-offs:

- A bad row reverts its entire handler batch; a bad handler batch reverts an across-handlers call.
- Lending schedule principal is nominal. Measured receipt shares can cover slightly less after
  rounded mints, withdrawals, or earlier purchases. A final purchase can therefore fail with
  `LendingHandler__InsufficientShares`. Separate rounded-up rows for the same buyer can also fail
  despite sufficient backing for one aggregate conversion. Both failures revert the entire batch.

  Interest can repair a dust gap, but zero or insufficient accrual cannot guarantee a repair.
  One additional underlying base unit is not sufficient for every repeated-buyer case.
  These availability risks are accepted; the bot simulates complete batches and omits failing rows.
  The owner can add backing, reduce a purchase, or exit principal through the available-share clamp.
  See the [AuditAgent dispositions](./audits/2026-10-06-Nethermind/README.md) and their reproductions.
- A user pause blocks purchases only. A governance deposit pause blocks new inflows only, preserving
  purchases and exits.
- Contracts are not proxies. Recovery from a defective immutable handler is a new route index plus
  manual user exit/re-entry, not an in-place upgrade or owner migration.

## External assumptions and unsupported cases

- Listed stablecoins, Money on Chain, lending markets, the Uniswap router/pools, WRBTC, and the MoC
  BTC/USD oracle remain correct and available. External illiquidity or pauses can revert purchases or
  withdrawals.
- Dex pricing assumes the input stablecoin is worth one USD; there is no stablecoin/USD oracle.
  A downward depeg can stop swaps at the configured BTC/USD-derived floor. An upward depeg does not
  raise that floor. A fair pool can pay the premium, but the floor does not require it; a tight
  quote-derived `minRbtcOut` protects the batch. The additional headroom with a weak caller minimum
  is accepted under the peg assumption.
- Users and the fee collector must accept native rBTC with empty calldata. EOAs and compatible
  payable contract accounts meet this requirement; permanently rejecting accounts are unsupported.
  They can create schedules and receive credits but cannot claim them through signer-bound payouts.
  A failed claim preserves the credit. Dex claims unwrap WRBTC and have the same requirement.
  No alternate recipient, wrapped claim, or owner rescue exists.
- Dex input tokens must have at most 18 decimals. Fee-on-transfer tokens and asynchronous or partial
  lending redemptions are unsupported.
- Sovryn charges a 0.1% exit fee on iToken burns. A user on the Sovryn route therefore receives less
  stablecoin than the principal debited on withdrawal, and each purchase spends the net amount
  redeemed. This is the venue-fee case in the accounting properties above, not a loss of shares.
  `make probe-sovryn-exit-fee` measures the live fee; see
  `test/mainnet-debug/sovryn-exit-fee/README.md`.
- LayerBank redemptions are sized for the Pool's current aToken burn rounding (Aave half-up `rayDiv`)
  and a liquidity index of at least one RAY. Upstream Aave v3 has since moved burns to round up. If the
  LayerBank Pool adopts that, a large share of LayerBank redemptions (purchases and withdrawals) revert
  on the exact share-consumption check until a re-derived handler is deployed on a new route; no claim
  is orphaned and no funds move. `make fork-layerbank` and `make fork-sovryn` assert the live rounding
  (`LayerBankLivePoolProbe`), so operations should rerun one of them whenever the Pool or aToken
  implementation changes. See `src/layerbank/README.md`.
  This upgrade assumption is separate from current half-up mint rounding: a fresh deposit can mint
  one share fewer than a full-principal purchase requires without any implementation change.
- Third-party incentive campaigns on a lending market (for example Merkl) are not claimed or
  distributed. Handlers pay out the market's native interest only.
- The bot must quote, simulate, group rows by handler, respect the protected-window workflow, and retry
  within the due UTC day when appropriate. Monitoring must track custom errors and the event ABI. A
  purchase emits no cadence-anchor event: `PurchaseRbtc__RbtcBought` is the purchase signal, and an
  indexer reads the new anchor from `getDcaSchedule` or recomputes it from the previous one.

## Earlier reviews and static analysis

[`audits/README.md`](./audits/README.md) lists every report. Two manual reviews from 2025 cover the
pre-relaunch code. The relaunch code has had two automated audits (Krait and Nethermind AuditAgent,
October 2026) and no third-party manual audit. The Krait report's **Resolution** section records its
decisions. The [AuditAgent companion](./audits/2026-10-06-Nethermind/README.md) records all six
dispositions separately from the unchanged original report. Accepted risks are stated in this guide.

Slither and Aderyn run on `src/` only (`make slither`, `make aderyn`). Slither exits non-zero because
its triaged findings are kept visible instead of suppressed. Each detector's classification, false
positive or accepted design, is in
[`docs/relaunch/R73-RELEASE_RECORD.md`](./docs/relaunch/R73-RELEASE_RECORD.md#static-analysis-triage).

## Reproducing the release gates

```bash
git submodule update --init --recursive
make check
make check-deploy
make fork-sovryn
make fork-layerbank
make fork-dex-path
make slither
make aderyn
```

CI pins Foundry v1.7.1; use the same version locally. Fork commands require `RSK_MAINNET_RPC_URL`.
`make check-deploy` is separate and slow because it recompiles everything under via-IR. The fork
suites run on Anvil/revm against live state and are not a Rootstock consensus or compiler proof. The
[README](./README.md#testing) describes each lane.

The specs under `docs/relaunch/` record why each choice was made. This guide and the verified source
state the current protocol without requiring that history.

## Required before mainnet

- An independent manual review of a frozen commit, with every finding resolved or explicitly accepted.
- Final sign-off on the launch configuration above. Fee changes apply to later purchases immediately;
  manager minimums constrain later creates and edits and do not rewrite existing schedules.
- A deployment of a `FOUNDRY_PROFILE=deploy` (`via_ir = true`) artifact to Rootstock testnet, verified
  on Blockscout. An optimizer-on, no-IR artifact has been deployed and verified there; the via-IR one
  has not.
- The release gates above, rerun on the frozen commit.

[`docs/relaunch/CUTOVER_RUNBOOK.md`](./docs/relaunch/CUTOVER_RUNBOOK.md) is the operator's sequence
for the deployment itself.
