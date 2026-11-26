# INVARIANT_CONTEXT — BitChill dca-contracts (Fizz Step 9a)

Read this file first, then the files it points to. Paths are relative to the repository root.

## 1. Protocol in one paragraph

Users fund dollar-cost-averaging schedules in a stablecoin through `DcaManager`. Each (token, routeIndex)
pair resolves through `OperationsAdmin` to one immutable handler, which holds the funds either idle or lent
(LayerBank = Aave-v3 fork, scaled aToken shares; Sovryn = iToken shares). An allowlisted swapper calls
`batchBuyRbtc(Batch)`; `DcaManager` checks cadence/pause/balance per row, debits each schedule's nominal
`purchaseAmount`, and calls the handler's `batchBuyRbtc(buyers, ids, amounts, minRbtcOut)`. The handler
retrieves the stablecoin (lending: per-row clamp to the buyer's share value, exact share burn), buys rBTC
on Money on Chain (`redeemFreeDoc`) or Uniswap V3 (`exactInput` with an oracle floor), checks exact input
consumption and `Q >= minRbtcOut`, then credits each buyer `floor(Q * net_i / G)` and the fee collector
`floor(Q * F / G)` in an `s_accumulatedRbtc` mapping that encodes `claimable + 1` (0 = never credited,
1 = fully withdrawn). Users claim rBTC with `withdrawAllAccumulatedRbtc`, withdraw principal with
`withdrawToken` (debits the requested nominal amount; lending pays measured cash, possibly less), withdraw
interest (share value above the user's summed principal on that route), or `topUpFromInterest` (moves
interest into a schedule's principal without moving cash).

## 2. Where to read

- Pre-audit map: `x-ray/x-ray.md`, `x-ray/invariants.md` (37 guards G-*, 22 single-contract I-*, 6
  cross-contract X-*, 3 economic E-*; 10 are "On-chain: No"), `x-ray/entry-points.md`.
- Spec/design notes: `AUDIT_GUIDE.md`, `README.md`, `src/layerbank/README.md`, `src/idle/README.md`.
- In-scope sources (`src/tropykus-legacy/` is OUT of scope):
  `src/DcaManager.sol`, `src/OperationsAdmin.sol`, `src/BitChillOwnable.sol`, `src/DcaManagerAccessControl.sol`,
  `src/TokenHandler.sol`, `src/StablecoinSource.sol`, `src/LendingHandler.sol`, `src/PurchaseRbtc.sol`,
  `src/PurchaseFees.sol`, `src/PurchaseMoc.sol`, `src/PurchaseUniswap.sol`,
  `src/idle/IdleHandler.sol`, `src/idle/IdleDocHandlerMoc.sol`, `src/idle/IdleHandlerDex.sol`,
  `src/layerbank/LayerBankHandler.sol`, `src/layerbank/LayerBankDocHandlerMoc.sol`, `src/layerbank/LayerBankHandlerDex.sol`,
  `src/sovryn/SovrynHandler.sol`, `src/sovryn/SovrynDocHandlerMoc.sol`, `src/sovryn/SovrynHandlerDex.sol`,
  `src/interfaces/*.sol`.
- Fuzz harness (already compiling, smoke-tested): `test/fizz/Base.sol`, `test/fizz/Snapshots.sol`,
  `test/fizz/Properties.sol`, `test/fizz/handlers/{Handlers,DcaManagerHandler,OperationsAdminHandler,LayerBankHandlerDexHandler,EnvironmentHandler}.sol`,
  `test/fizz/mocks/FizzIToken.sol`. Mocks reused from the repo: `test/mocks/{MockStablecoin,MockMocProxy,MockMocOracle,MockWrbtcToken,MockSwapRouter02,MockLayerBank}.sol`.
- Earlier AI scan of this code (2 findings, 28 leads; unconfirmed):
  `audits/2026-10-13-Pashov-Skills/dca-contracts-pashov-ai-audit-report-20261013-135445.md`.
- Existing Foundry invariant suites (do not duplicate blindly; they cover narrower fixtures):
  `test/ai-generated/fuzz/README_INVARIANTS.md`.

## 3. Harness topology (what the fuzzer can actually observe)

One `DcaManager` + one `OperationsAdmin`, owner = `admin` (the fuzz contract). Five assigned routes in
`routes[]` (struct `Route {token, routeIndex, handler, lending, dex}`):

| token | route | handler | venue | lending market |
|---|---|---|---|---|
| DOC | 0 | IdleDocHandlerMoc | MockMocProxy | — |
| DOC | 1 | LayerBankDocHandlerMoc | MockMocProxy | MockLayerBankAToken/Pool (DOC) |
| DOC | 2 | SovrynDocHandlerMoc | MockMocProxy | FizzIToken |
| USDRIF | 0 | IdleHandlerDex | MockSwapRouter02 + MockWrbtcToken, MockMocOracle floor | — |
| USDRIF | 1 | LayerBankHandlerDex | same | MockLayerBankAToken/Pool (USDRIF) |

Actors: `actors[]` (3 `Actor` contracts with `receive()`), each minted 1,000,000 DOC and USDRIF and
approving every handler. `swappers[]` = 2 allowlisted EOAs; `swapper` is the current one.
`feeCollector` = an `Actor`, initial collector on all five handlers; `setFeeCollector` rotates among
`feeCollector` and the actors (a collector can also be a buyer). `trackedSchedules[]` lists every live
schedule the harness created `{token, scheduleId, owner, routeIndex}` and drops it on delete — this is
the complete set of live schedules (all creation goes through the handlers).

Mock venue behaviour that matters for properties:
- MockMocProxy: pulls exactly `docAmount` (no `setFreeDoc` cap is ever set), pays `docAmount / 50_000` wei
  rBTC. Fixed price; MoC route ignores `minRbtcOut` in the venue, only `PurchaseRbtc` checks it.
- MockSwapRouter02: consumes 100% input, pays `amountIn * 997 / (1000 * dexRouterPrice)` as WRBTC to the
  handler; reverts "Insufficient output amount" if `amountOutMinimum` > that. `dexRouterPrice` (Base) and
  `MockMocOracle` prices move independently in [40_000, 60_000] via `EnvironmentHandler`. The oracle can
  be marked invalid. Two oracles (`mocOracle`, `mocOracleAlt`) for `setMocOracle`.
- MockLayerBankAToken: `scaledBalanceOf` = raw shares; half-up `rayDiv` on mint and burn (as Aave v3);
  index grows 5%/yr with time until `env_bumpLayerBankIndex` sets an override, after which it only rises
  on later bumps (never falls). It mints missing underlying on payout, so liquidity never runs out.
- FizzIToken (Sovryn): `tokenPrice()` settable, can FALL (bad debt) within [0.5, 3]e18; mint floors
  `received * 1e18 / price`; burn pays `floor(shares * price / 1e18)` minus an optional exit fee
  (0..100 bps) that stays in the market; mints missing underlying on payout.
- Donations: `env_donateStablecoin` sends stray stablecoin straight to a handler; `env_donateETH`
  force-sends native rBTC to a handler. Neither is credited to anyone.
- Time: `env_skipDays` jumps to a later UTC midnight + offset; the fuzzer also warps/rolls between calls.
  `PROTECTED_PURCHASE_WINDOW_BLOCKS = 5`.
- Launch-like fee settings: min 20 bps, max 100 bps, lower bound 250e18; `setFeeRateParams` may move
  them anywhere with `minFeeRate <= maxFeeRate <= 500`. `MIN_PURCHASE_AMOUNT` 25e18 per token
  (owner can change). `minPurchasePeriod` starts at 1 day (launch is 7). `maxSchedulesPerToken` 10
  (owner can change, including to 0 and below live counts).

## 4. Step 9a extraction

AGGREGATE_VARIABLES
- `DcaManager.s_dcaSchedules[token][id].tokenBalance` (written by create, deposit, purchase debit,
  withdraw, top-up); `ProtocolSettings.scheduleNonce`; `s_scheduleIds[user][token]` (push/swap-pop);
  `s_userMutationsAllowedFromBlock`.
- `LendingHandler.s_shares[user]` (private; `getUserShares`) vs the handler's receipt-share balance
  (`scaledBalanceOf` / iToken `balanceOf`).
- `PurchaseRbtc.s_accumulatedRbtc[account]` (private, `claimable + 1` encoding; `getAccumulatedRbtcBalance`
  returns claimable) vs the handler's native balance (MoC) or WRBTC balance (Dex).
- Stablecoin held by an idle handler vs Σ `tokenBalance` on that route.

PAIRED_OPERATIONS
- createDcaSchedule / deleteDcaSchedule; depositToken / withdrawToken (+ withdrawTokenAndInterest);
  LendingHandler `_depositToken` mint / `_redeemShares` burn; `_creditRbtc` / `_withdrawRbtcChecksEffects`;
  `setSchedulePaused(true/false)`; `addSwapper` / `revokeSwapper`; `setDepositsPaused(true/false)`;
  `setPurchasePathAllowed(true/false)`; `activateProtectedPurchaseWindow` / window expiry.

CONVERSION_FUNCTIONS
- `LendingHandler._stablecoinToShares` (ceilDiv, rounds up) and `_sharesToStablecoin` (floor).
- `LayerBankHandler._underlyingForExactScaledBurn` (floor then +1 if half-up rayDiv falls short).
- `PurchaseFees._calculateFlatFeeAndNetWeights`, `_calculateVariableFee` (variable curve above lower bound).
- `PurchaseRbtc._creditPurchases` `floor(Q * net_i / G)`, fee `floor(Q * F / G)`.
- `PurchaseUniswap._getAmountOutLowerBound` = `amount * 10^(18 - decimals) * percent / oraclePrice`.

ACCESS_CONTROL
- `onlyOwner` (Ownable2Step, renounce reverts) on every setter; `onlySwapper` (OperationsAdmin allowlist)
  on window + batch; `onlyDcaManager` on every fund-moving handler call; `_callersSchedule` owner check
  on every schedule mutator; `setPurchasePath` = owner or swapper; `restore*Approval` permissionless.

## 5. Accepted-by-design behaviour (do not write SHOULD-HOLD properties that contradict these)

- Raising the token minimum, the minimum period, or lowering `maxSchedulesPerToken` does not rewrite
  existing schedules (x-ray I-4, I-6, I-8; spec says so).
- On lending routes principal is nominal: after a share-value fall a schedule's `tokenBalance` can exceed
  the value of its owner's shares; a batch row is clamped to the buyer's remaining share value and the
  schedule is still debited the full `purchaseAmount` (R114 design; x-ray X-2, X-3, E-3). Withdrawals
  debit the requested amount and pay measured cash, which can be less (exit fee, loss).
- A `withdrawToken` / `deleteDcaSchedule` on a lending route can pay less than the debit; a zero-share
  user withdraws zero tokens.
- Revoking a swapper leaves its window and its chosen path in place (x-ray X-5).
- `updatePurchasePeriod` keeps the anchor, so cutting the period can make a schedule due again; delete +
  create starts a new schedule with anchor 0 (x-ray I-12; pinned by an existing test).
- Fee/credit flooring leaves under one wei per row plus one per fee on the handler.
- Stray donations sit on a handler, credited to no one.

## 6. Open leads from the earlier AI scan worth turning into properties

- Finding 1: batch `minRbtcOut` is absolute and does not scale with the input the batch actually spends
  (deposits / creates during a protected window can change it; lending clamps can shrink it).
- Leads: window does not block `depositToken` / `createDcaSchedule`; `depositToken` computes the new balance
  before the handler call; LayerBank +1 round-up burn sizing and exact-burn check (`G-26`); Sovryn small
  remainder burns; a withdrawal after a lending loss taking other schedules' shares (same user); zero-value
  transfers; interest redeem paying zero reverting `withdrawTokenAndInterest`; Uniswap floor using a $1
  stablecoin and an oracle of any age; per-batch average price across rows; swapper path switching.
