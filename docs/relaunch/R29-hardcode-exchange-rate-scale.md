# R29 — Hardcode each adapter’s exchange-rate scale

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 20. Stack on R28 (PR 19, GitHub [#63](https://github.com/BitChillRSK/dca-contracts/pull/63)). Land **before** R22 deploy/CI (now PR 21) so that PR does not freeze a constructor arg that is a protocol constant.

## Objective

Sovryn and Tropykus take `exchangeRateDecimals` as a constructor argument; LayerBank hardcodes `RAY` (`1e27`). Bind each adapter’s scale as a constant, the way LayerBank already does, so a deploy cannot pass `Constants.sol`’s `1e18` into an Aave handler (withdrawals 1e9× too large).

## Background

The scale is a property of the protocol’s rate, not a deployment knob. Compound/Sovryn mantissas are `1e18`. Aave’s liquidity index is RAY (`1e27`). [R22-layerbank-handler.md](./R22-layerbank-handler.md) already forbade a LayerBank constructor arg for that reason. Sovryn/Tropykus still take the arg because they were written first and share `EXCHANGE_RATE_DECIMALS` in `script/Constants.sol`.

`TokenLending` / `LendingErc20Handler` still take the value — the base stays protocol-agnostic. The adapter binds it.

Named on R28 review (GitHub #63): copy LayerBank’s pattern onto the other two; do not add the arg to LayerBank.

## Open product decisions

**none**

## Scope

- [x] `SovrynErc20Handler`: `uint256 public constant EXCHANGE_RATE_DECIMALS = 1e18`; constructor drops the arg and passes the constant into `LendingErc20Handler`.
- [x] `TropykusErc20Handler`: same constant and constructor shape.
- [x] Leaves drop the arg and stop forwarding it: `SovrynDocHandlerMoc`, `SovrynErc20HandlerDex`, `TropykusDocHandlerMoc`, `TropykusErc20HandlerDex`.
- [x] Call sites that construct those types drop the last arg (`script/DeployMocSwaps.s.sol`, `DeployDexSwaps.s.sol`, `DeployUsdrifHandler.s.sol`, handler unit tests, `DcaDappTest` / shared harness if it `new`s a leaf, fuzz/invariants, any other `new Sovryn*` / `new Tropykus*`).
- [x] LayerBank unchanged (already `RAY`).
- [x] `script/Constants.sol` `EXCHANGE_RATE_DECIMALS` may remain where tests use it as conversion math (not as a constructor arg). Do not delete it unless nothing still references it.

## Out of scope

- [ ] Changing `TokenLending` / `LendingErc20Handler` to drop their constructor arg.
- [ ] Adding `exchangeRateDecimals` to LayerBank.
- [ ] R22 deploy/CI index map, harness split, or CI lanes.
- [ ] R9 events. Diamond-resolver mixin. Idle constructors.

## Files likely touched

- `src/sovryn/SovrynErc20Handler.sol` and Moc/Dex leaves
- `src/tropykus-legacy/TropykusErc20Handler.sol` and Moc/Dex leaves
- `script/DeployMocSwaps.s.sol`, `script/DeployDexSwaps.s.sol`, `script/DeployUsdrifHandler.s.sol`
- Matching tests that pass `EXCHANGE_RATE_DECIMALS` into those constructors

## Required tests

No product behavior change. Compiler errors from the dropped arg are the first signal; then:

```
make check
make fork-sovryn
make fork-tropykus
```

Assert `sovrynHandler.EXCHANGE_RATE_DECIMALS() == 1e18` and `tropykusHandler.EXCHANGE_RATE_DECIMALS() == 1e18` (LayerBank already asserts `RAY() == 1e27`). Fork tests: no new fork-specific assertions; run before push.

## Success criteria

- [x] Three adapters bind scale as a public constant; none take it as a constructor arg.
- [x] `TokenLending` still receives the value from the adapter.
- [x] Deploy scripts and tests compile without passing the dropped arg.
- [x] `make check` and both fork targets pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: Sovryn and Tropykus adapter/leaf constructors lose the last `uint256`. Fresh relaunch deployments; no live cutover.
- Scripts: stop passing `EXCHANGE_RATE_DECIMALS` into those constructors. Local/test only; do not `--broadcast`.
- Cutover: none.
