# AGENTS.md

Foundry Solidity repo for BitChill DCA-in contracts on Rootstock (`0.8.19`, EVM `london`). Users talk to `DcaManager`; a swapper bot triggers purchases; handlers hold funds and talk to lending, Money on Chain, and Uniswap.

## Read order

1. This file.
2. The assigned spec under `docs/relaunch/` (required before Solidity changes). `.cursor/relaunch-plan.md` is private planner notes — not a task list.
3. Start from the spec’s file list. Expand only through imports, inheritance, interfaces, mocks, failing tests, and compiler errors. Name extra files in the PR.

Do not implement optional/further-review items unless the spec assigns them. Sibling repo `dca-out-contracts` is out of scope unless named.

## Layout

Do not Grep/`Glob` `out/`, `cache/`, or `lib/` (see `.cursorignore`). Open a `lib/` path only when a `src/` import points there.

```
DcaManager          user + swapper entry; schedules
OperationsAdmin     roles; token × lending-index → handler
FeeHandler          fee math (also inherited by Purchase*)
TokenHandler        deposit/withdraw stablecoin (owns FeeHandler)
TokenLending        share ↔ underlying conversion (no TokenHandler inherit)
PurchaseRbtc        accumulated rBTC; withdraw to signer
PurchaseMoc         MoC redeem DOC → rBTC
PurchaseUniswap     Uniswap V3 → WRBTC

Handlers = TokenHandler + TokenLending + a Purchase*:
  TropykusErc20Handler ─┬─ TropykusDocHandlerMoc      (+ PurchaseMoc)
                        └─ TropykusErc20HandlerDex    (+ PurchaseUniswap)
  SovrynErc20Handler   ─┬─ SovrynDocHandlerMoc        (+ PurchaseMoc)
                        └─ SovrynErc20HandlerDex      (+ PurchaseUniswap)
```

- `src/interfaces/` — first-party ABIs; keep in sync with implementations.
- `test/unit/DcaDappTest.t.sol` — shared harness; **requires** `SWAP_TYPE` and `LENDING_PROTOCOL` (no fallback).
- `test/unit/`, `test/mocks/`, `test/ai-generated/` — unit / mocks / extra + fuzz.
- `script/` — deploy helpers. Do not `--broadcast` or talk to live contracts.

## Protocol invariants

Unless the assigned spec explicitly changes one:

1. **Balance-delta cash** — after a call that should move tokens or native to us, measure `balanceOf` / `address(this).balance` (or the user’s balance when paying the user). Do not treat integrator return values as received funds.
2. **No view as redeem ceiling** — do not cap redemptions with `assetBalanceOf`, `profitOf`, snapshots, or `tokenPrice` as “DOC we will get.” Rates may size share burns, then clamp to shares held.
3. **rBTC pays the signer** — withdrawals go to `msg.sender`. No `to` parameter; no owner rescue of another account’s rBTC.
4. **Index addresses and `scheduleId` only** — do not index amounts, timestamps, strings, bytes, or arrays.
5. **No assembly in purchase paths** — `buyRbtc`, `batchBuyRbtc`, `_rBtcPurchaseChecksEffects`, fee loops — unless the spec authorizes it.

## Tests and done-gate

- Targeted tests for the spec first. Document exact commands in the PR.
- **Done-gate:** `make check` (`forge build` + `make moc-tropykus`). Local Tropykus targets remain for mock-based tests.
- **CI (every PR):** `make moc-sovryn` and `make dex-sovryn` only. Tropykus mint is paused on live Rootstock (`C2`); do not add tropykus jobs back.
- Defaults: `SWAP_TYPE=mocSwaps`, `LENDING_PROTOCOL=tropykus`, `STABLECOIN_TYPE=DOC`. Dex paths often use `STABLECOIN_TYPE=USDRIF`.
- `make slither` if slither is installed; not part of `make check` (no clean baseline yet).
- Do not `forge fmt` existing files unless the spec says to (`src/` is not fmt-clean).
- Fork tests (`make fork-*`) need an RPC and are not in CI. Tropykus fork deposits will fail while mint is paused.

## PRs

Small, behavior-scoped, reviewable history. No drive-by refactors. Do not commit secrets or `.env`. Use `.github/PULL_REQUEST_TEMPLATE.md`. Point at the spec; do not restate the invariants — say whether they still hold.
