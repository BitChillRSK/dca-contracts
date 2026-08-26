# R22 — LayerBank DOC + MoC handler

Status: **in review** · Assigned: yes · Optional/further-review: no

PR 15 of R22. Redeem-helper naming is PR 16 (R25). Deploy/constants/harness/CI index-map work is PR 18.

> Note: PR numbers below predate later reorders (R22 deploy/CI is now PR 28; R9 is PR 29). See [`IMPLEMENTATION_ORDER.md`](./IMPLEMENTATION_ORDER.md).

## Objective

Ship a LayerBank lending handler for DOC + MoC as the index-1 twin of Tropykus and Sovryn: per-user virtual **scaled aToken** shares, balance-delta cash from day one (including R21 deposit returns), and `getUsersLendingTokenBalance(user)`. Talk to the live Aave-v3-style Pool, not the stale v2 Core. Do not remap the live index map or rewrite the shared test harness in this PR.

## Background

PR 58 first shipped a faithful Tropykus/Sovryn twin of LayerBank **v2** (Compound-style Core + `onlyCore` LToken). That deployment never listed DOC.

Live LayerBank DOC (verified Rootstock 2026-08-24 via `RSK_MAINNET_RPC_URL`) is on a newer Aave-v3-style Pool. There is no point keeping the v2 integration. Replace it in place: same BitChill handler shape, different third-party ABI.

| Motion | Tropykus kToken | Sovryn iToken | LayerBank (live) |
| --- | --- | --- | --- |
| Deposit underlying, receive shares | `mint(uAmount)` → error code | `mint(receiver, uAmount)` | `Pool.supply(asset, amount, onBehalfOf, referralCode)` — no return. Pool `transferFrom`s the handler to the aToken |
| Redeem by underlying | `redeemUnderlying(uAmount)` | (sized as shares, then `burn`) | `Pool.withdraw(asset, amount, to)` → `uint256` (untrusted) |
| Redeem by shares | `redeem(kAmount)` | `burn(receiver, iAmount)` | No share-amount withdraw. Convert scaled shares with the normalized income, then `Pool.withdraw` |
| Rate (mutating / view) | `exchangeRateCurrent()` / `exchangeRateStored()` | `tokenPrice()` (view) | `Pool.getReserveNormalizedIncome(asset)` — view, RAY (`1e27`), already includes pending interest |
| Failure mode | `uint` error code, 0 = success | revert | revert; `supply` returns nothing; `withdraw` returns an amount — treat it as untrusted |

**Do not call the v2 Core.** `Core.allMarkets()` on `0xc30991623fb2a63E6e1B59A29987E1EEE57447bF` is still only lRBTC / lRIF / lUSDCe / lUSDT / lWETH. The v2 README (`layerbank-foundation/v2-contracts`) is stale. Implement from the live Pool/aToken ABI (Blockscout), not from that README.

### Live addresses (Rootstock, 2026-08-24)

| | Address | Notes |
| --- | --- | --- |
| aToken | `0x3F04280C66314b78E9712A41BF8C1A214460cAa2` | lRooDOC, “LayerBank Rootstock DOC”, `ATokenInstance` proxy. Implementation `0x307d72f7c793b4484ddd7d871a54cf292a2cbac5`. **No** `core()`, **no** `accruedExchangeRate()`, **no** `underlying()`. |
| Underlying | `0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db` | DOC |
| Pool | `0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9` | Aave-v3 Pool proxy. Implementation `0x88919001dfc1cbf7ec166b3294fddb03e53c0f34`. `ADDRESSES_PROVIDER` `0x0c32000a7d7d4454a3CC3B700a8b12678ade7052` |
| Total supplied | ~199,584 DOC | UI ~$200K |
| Cash in aToken | ~56,907 DOC | rest borrowed |

Blockscout: [aToken](https://rootstock.blockscout.com/address/0x3F04280C66314b78E9712A41BF8C1A214460cAa2), [Pool](https://rootstock.blockscout.com/address/0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9).

Live aToken surface this handler calls: `POOL()`, `UNDERLYING_ASSET_ADDRESS()`, `scaledBalanceOf(address)`. Live Pool: `supply(address,uint256,address,uint16)`, `withdraw(address,uint256,address) returns (uint256)`, `getReserveNormalizedIncome(address)`.

### Share accounting (RAY, not rebasing `balanceOf`)

Aave aTokens **look** rebasing via `balanceOf` but internally store **scaled** balances and a RAY (`1e27`) liquidity index (`getReserveNormalizedIncome`). Store scaled share deltas (analog of kToken/iToken amounts). Convert with the normalized income the way Tropykus uses `exchangeRateCurrent`. If the handler instead stores rebasing `balanceOf`, interest accounting will desync.

Constructor hardcodes RAY (`1e27`) into `TokenLending`. Do not take `exchangeRateDecimals` as a constructor argument — Tropykus/Sovryn's `EXCHANGE_RATE_DECIMALS` (`1e18`) is one line away in `Constants.sol` and would size withdrawals 1e9× too large. Do not change Tropykus/Sovryn.

Cash rule (R1/R20, invariant 1): after `supply`, credit `aToken.scaledBalanceOf(handler)` delta. After `withdraw`, pay the measured `DOC.balanceOf` delta (handler, then `safeTransfer` to the user). Do not treat Pool return values as cash received. Do not cap redemptions with Aave views (`getReserveData`, liquidity index, `balanceOf` as “DOC we will get”).

R21: `super.depositToken` already returns hop-1 received; `Pool.supply` that amount, then credit the measured **scaled** share delta.

R16: hook names are `_retrieveStablecoin` / `_redeemLendingToken` — **[R25](./R25-lending-redeem-naming.md)** later renamed this handler's redeem hooks to `_redeemByUnderlying` / `_redeemByShares`. Do not reintroduce `_redeemStablecoin`.

External incentives are out of scope (`EXTERNAL_REWARDS.md`). The handler must not claim Merkl / LAB / `claimLab` / harvest. R9 later emits `TokenLending__UserSharesUpdated` on this handler — every share mint/burn site must be a single, complete update to the per-user scaled mapping so that event can cover deposits, withdrawals, interest, and single/batch purchases.

Constructor: same shape as `TropykusErc20Handler` except **no** `exchangeRateDecimals` argument — `TokenLending` is initialized with hardcoded `RAY` (`1e27`). Read the Pool from `aToken.POOL()` (v2 used `lToken.core()`). Revert if Pool is unset. Revert `LayerBankErc20Handler__UnderlyingMismatch` if `aToken.UNDERLYING_ASSET_ADDRESS()` is not the stablecoin — the live token has no `underlying()`. Do not add a Pool constructor arg. Do not copy the unused `minPurchaseAmount` leftover that `TropykusDocHandlerMoc` / `SovrynDocHandlerMoc` carried at the time (**[R25](./R25-lending-redeem-naming.md)** dropped it there too).

Redeem-to-user: Aave `withdraw(..., to)` exists; still withdraw **onto the handler**, measure the DOC delta, then `safeTransfer` to the user. No `to` on rBTC.

Live Aave `withdraw` reverts on insufficient cash (ERC20 transfer from the aToken) rather than under-paying. An illiquid reserve therefore aborts the entire `batchBuyRbtc`, not one buyer — same shape as Tropykus/Sovryn. Cash today is ~57k of ~200k supplied. Flag this for PR 18; no code change.

`safeApprove` pattern: leave as the Tropykus/Sovryn convention. Spender is the **Pool** (it `transferFrom`s the handler), not the aToken.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 15. Implement without asking.

## Scope

- [x] Replace the v2 Core/LToken surface in place. Delete `ILToken` / `ILayerBankCore`. Do not leave dead `onlyCore` / `accruedExchangeRate` / `setCore` one-shot comments as if they still applied.
- [x] `LayerBankErc20Handler` (`TokenHandler` + `TokenLending`) with per-user scaled `s_aTokenBalances` and `getUsersLendingTokenBalance`.
- [x] `LayerBankDocHandlerMoc` (`LayerBankErc20Handler` + `PurchaseMoc`).
- [x] Slim `ILayerBankAToken` / `ILayerBankPool` next to the handler (only the functions this handler calls). Constructor checks `UNDERLYING_ASSET_ADDRESS()` matches the stablecoin and `POOL()` is set. `ILayerBankErc20Handler` holds the two constructor errors (same pattern as `IIdleErc20Handler`); do not put custom errors on the implementation contract.
- [x] Deposit: hop-1 via `super.depositToken`; approve the **Pool**; `Pool.supply(stable, received, handler, 0)`; credit aToken `scaledBalanceOf` delta; revert `TokenLending__LendingProtocolDepositFailed` if the delta is 0.
- [x] Withdraw / single retrieve: clamp to the user's converted scaled balance (same events as Tropykus/Sovryn), then `Pool.withdraw(stable, amount, handler)`. Pay the measured DOC delta. Skip the Pool call when the underlying amount is 0 (live Aave reverts `InvalidAmount`).
- [x] Interest: size with `getReserveNormalizedIncome`, convert scaled shares to underlying, `Pool.withdraw` onto the handler, transfer the measured DOC to the user.
- [x] Batch retrieve: debit each buyer's rounded-up share of the total scaled burn or revert `TokenLending__InsufficientLendingTokenBalance`; one `Pool.withdraw`; revert `TokenLending__ZeroStablecoinReceived` if the DOC delta is 0 (Sovryn/R20, not Tropykus's emit-on-zero).
- [x] Dedicated unit tests under `test/ai-generated/unit/layerbank/` plus mocks of Pool + aToken (scaled balances, RAY index, optional silent-zero / zero-mint / payout-cap knobs). Add-on `script/DeployLayerBankHandler.s.sol` (local/fork tests deploy the mocks). A deployment test and a standalone DcaManager path go through that script.
- [x] Live fork probe against this Pool if `RSK_MAINNET_RPC_URL` is set (runs on `make fork-sovryn` at tip; skip when the aToken has no code, e.g. Anvil or a pre-deploy Tropykus pin). Do not add `LENDING_PROTOCOL=layerbank` as a first-class lane.
- [x] Update `src/layerbank/README.md` and the `AGENTS.md` Layout / protocol-specific interface list.

## Out of scope

- [ ] `script/Constants.sol` index remap (`LAYERBANK_INDEX = 1` replacing Tropykus), `DeployMocSwaps` / `DeployDexSwaps` registration, `MocHelperConfig` live Pool/aToken fields, `DcaDappTest` split, `ILendingToken` deletion, CI matrix (`none` / `layerbank` / `sovryn`) — those are PR 18. This PR may register LayerBank at index 1 **inside dedicated tests** on that test's `OperationsAdmin` (overwriting Tropykus there is fine).
- Ops (PR 18, no code change wanted): live `Pool.withdraw` reverts on insufficient aToken cash, so an illiquid DOC reserve blocks the entire `batchBuyRbtc` for every buyer in that batch, not just the one who cannot be served. Same shape as Tropykus/Sovryn; cash today is ~57k of ~200k supplied.
- [ ] LayerBank Uniswap / USDRIF handler.
- [ ] Merkl / LAB / `claimLab` / harvest / reward-debt / unwrap.
- [ ] R9 `TokenLending__UserSharesUpdated`.
- [ ] Renaming Tropykus in place. Creating `src/moc-lending/`.
- [ ] Adapting the shared `DcaDappTest` / Makefile / CI matrix so `LENDING_PROTOCOL=layerbank` is a first-class lane.
- [ ] Round-up solvency regression (`sum(virtual scaled) <= scaledBalanceOf(handler)` under Aave-like round-nearest burns; must fail if TokenLending rounded down) — required in PR 18 ([R22-deploy-ci.md](./R22-deploy-ci.md)), not optional later.

## Files likely touched

New:

- `src/layerbank/ILayerBankAToken.sol`
- `src/layerbank/ILayerBankPool.sol`
- `src/layerbank/ILayerBankErc20Handler.sol`
- `test/unit/layerbank/LayerBankLivePoolProbe.t.sol`

Replace (delete v2 files):

- `src/layerbank/ILToken.sol`
- `src/layerbank/ILayerBankCore.sol`

Edit:

- `src/layerbank/LayerBankErc20Handler.sol`
- `src/layerbank/LayerBankDocHandlerMoc.sol`
- `test/mocks/MockLayerBank.sol`
- `test/ai-generated/unit/layerbank/LayerBankErc20HandlerTest.t.sol`
- `test/ai-generated/unit/layerbank/LayerBankDocHandlerMocTest.t.sol`
- `test/ai-generated/unit/layerbank/LayerBankDcaManagerTest.t.sol`
- `script/DeployLayerBankHandler.s.sol`
- `test/unit/deployment/LayerBankHandlerDeploymentTest.t.sol`
- `src/layerbank/README.md`
- `script/Constants.sol`
- `AGENTS.md`
- `docs/relaunch/README.md` (keep Status on #58)
- `docs/relaunch/IMPLEMENTATION_ORDER.md` (PR 15 ABI is Pool/aToken, not v2 Core/lToken)

## Required tests

Targeted:

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods \
  --match-path "test/ai-generated/unit/layerbank/**" -j 1

SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --match-contract LayerBankHandlerDeploymentTest -j 1
```

Then the done-gate and the pre-push fork lanes (see `AGENTS.md`):

```
make check
make fork-sovryn
make fork-tropykus
```

`make fork-sovryn` also runs `LayerBankLivePoolProbe` (under `test/unit/`, not `ai-generated`). Skip when the live aToken has no code.

Behaviors to assert:

- Deposit mints scaled aTokens to the handler (not the user); `getUsersLendingTokenBalance` equals the measured `scaledBalanceOf` mint, not a Pool return (mock may lie about `withdraw`'s return; `supply` has none on the live ABI).
- After interest accrues, virtual shares still equal `scaledBalanceOf`, not rebasing `balanceOf`.
- Withdraw pays the user and debits only that user's virtual scaled balance. Oversize withdraw clamps.
- Zero-payout redeem (shares burnt, no DOC) reverts `TokenLending__ZeroStablecoinReceived` and leaves the virtual balance intact. Same for the batch path (Sovryn/R20).
- Deposit with a successful `Pool.supply` that mints 0 scaled aTokens reverts `TokenLending__LendingProtocolDepositFailed`.
- Withdraw pays the measured DOC delta when the mock pays a shortfall. Live Aave `withdraw` reverts on insufficient cash rather than under-paying; the payout-cap hook is deliberately more permissive so invariant 1 has coverage. Do not "fix" the mock to match live.
- Interest accrues with the RAY normalized income; `withdrawInterest` pays the user; no-interest is a no-op.
- `buyRbtc` / `batchBuyRbtc` spend DOC via MoC and credit accumulated rBTC; virtual scaled balances fall.
- `batchBuyRbtc` / `_batchRetrieveStablecoin` revert `TokenLending__InsufficientLendingTokenBalance` if any buyer cannot cover their share.
- Dedicated DcaManager path: create / buy / withdraw at the test's index 1 against this handler.
- Constructor reverts if `POOL()` is unset or `UNDERLYING_ASSET_ADDRESS()` mismatches the stablecoin. RAY is hardcoded (`1e27`); there is no `exchangeRateDecimals` constructor arg.
- `DeployLayerBankHandler.run()` reverts unless `Environment.LOCAL` (Anvil). Fork tests use `deployMocksAndHandler` (no broadcast). A real RSK RPC without `REAL_DEPLOYMENT=true` is `FORK`, not `MAINNET`.
- Live probe (fork tip): `aToken.POOL()` is the live Pool; `UNDERLYING_ASSET_ADDRESS()` is DOC; `getReserveNormalizedIncome` is RAY-scale (`>= 1e27`); `core()` / `accruedExchangeRate()` are absent; handler constructs against the live aToken.
- Existing Tropykus and Sovryn lanes in `make check` are unchanged.

Fork tests: `make fork-sovryn` and `make fork-tropykus` before push (`AGENTS.md`). This PR does not add `LENDING_PROTOCOL=layerbank`. The live Pool probe is view + construct only (no mutating supply that needs a DOC whale).

## Success criteria

- [x] `LayerBankDocHandlerMoc` is constructable with an aToken whose `POOL()` is set and whose `UNDERLYING_ASSET_ADDRESS()` matches the stablecoin; it reverts if Pool is unset or the underlying mismatches.
- [x] Deposits, withdrawals, interest, and MoC purchases use balance-delta cash and exact per-user virtual **scaled** aToken balances. Batch redeem reverts on insufficient shares or zero DOC received.
- [x] No Merkl/LAB claim path. No empty per-protocol lending interface. No leftover v2 Core/lToken types.
- [x] `DeployLayerBankHandler` deploys `LayerBankDocHandlerMoc` via mocks on local and fork tests and can register it. `DeployMocSwaps` / `DeployDexSwaps` / `DcaDappTest` / `Constants.sol` indexes are unchanged (PR 18).
- [x] Done-gate lanes pass. `make fork-sovryn` and `make fork-tropykus` pass before push.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none). Invariant 1 applies to Pool `supply`/`withdraw`. Invariant 2: no `getReserveData` / liquidity-index / `balanceOf` redeem ceiling.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: `LayerBankErc20Handler` / `LayerBankDocHandlerMoc` take the aToken (not a v2 lToken) and do **not** take `exchangeRateDecimals` — `TokenLending` is initialized with hardcoded RAY (`1e27`). Constructor reads Pool from `aToken.POOL()`. Reuses `ITokenLending` events/errors. No change to existing handler ABIs.
- Scripts: add-on `DeployLayerBankHandler`. `run()` is Anvil-only; live Pool / aToken addresses and index-1 registration on the main deploy path are PR 18.
- Cutover: none in this PR. Frontend cannot target LayerBank until PR 18 assigns the handler on the new admin. An illiquid market reverts `Pool.withdraw` for the whole `batchBuyRbtc`, not per buyer — ops note for whoever wires the live market (cash ~57k of ~200k supplied; same shape as Tropykus/Sovryn; no code change).
