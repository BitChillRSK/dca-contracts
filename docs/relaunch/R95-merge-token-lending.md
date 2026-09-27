# R95 — Merge `TokenLending` into `LendingErc20Handler`, and source-order cleanups

Status: **implemented** · GitHub [#161](https://github.com/BitChillRSK/dca-contracts/pull/161) · Assigned: yes · Optional/further-review: no · Stack on: [#160](https://github.com/BitChillRSK/dca-contracts/pull/160)

## Objective

Delete `src/TokenLending.sol` and move its scale immutable and its two share ↔ stablecoin conversion
helpers into `LendingErc20Handler`, which then inherits `ITokenLending` directly. In the same pass, fix
four source-only inconsistencies:
- give the scale immutable an explicit visibility;
- convert the `PurchaseRbtc` constructor's two-line `///` run to `/** */`;
- declare constants, then immutables, then storage in `PurchaseUniswap` and `FeeHandler`;
- make every first-party `src/` import relative.

Runtime bytecode is identical under both profiles, so this PR changes no behavior.

This spec also records the verdict on every candidate from the 2026-09-27 review of PRs 138–160 (see
**Review disposition**). [R96](./R96-ceildiv-and-one-route-class-getter.md) and
[R97](./R97-redeem-lending-exits-to-user.md) carry the two executable follow-ups.

## Background

### Why two files existed

[R28](./R28-lending-erc20-handler.md) (PR 19) extracted `LendingErc20Handler is TokenHandler,
TokenLending` and wrote "`TokenLending` stays conversion math … do **not** lift `depositToken` /
`s_*Balances` into `TokenLending`." That is a rule against turning `TokenLending` into a second handler.
It is not a reason to keep the conversion math out of `LendingErc20Handler`. The PR 22 plan then listed
"merge `TokenLending` into `LendingErc20Handler`" among the deliberate non-candidates, and
[R89](./R89-post-r88-review-candidates.md) repeated it under **Already decided**, citing R28. Neither
added a reason of its own.

Today `TokenLending` holds one immutable and two internal helpers:
- It has exactly one child, `LendingErc20Handler`.
- It declares `is ITokenLending` but implements none of that interface. The inheritance is left over
  from before R28, when `TokenLending` was the lending surface.
- No consumer repository references the contract; only the `TokenLending__` error and event names
  are visible.

After the merge, `ITokenLending` and `LendingErc20Handler` are a real interface/implementation pair that
a reader can diff (`AGENTS.md` **Section headers and function order**).

Decided by the human on 2026-09-27: "Right now I don't see why they should be two different files."

### What does not change

- **The `TokenLending__` prefix on errors and events.** It names the `ITokenLending` surface, and
  renaming it would change selectors and topics for `bitchill-monitoring`.
- **[R88](./R88-post-r87-structural-cleanups.md)'s rejection of a shared public scale.** Adapters
  keep their own `EXCHANGE_RATE_DECIMALS` constant. The immutable they pass through the constructor
  only moves to a different contract. It stays `internal`, so there is no new getter.
- **The conversion helpers.** They keep their bodies and NatSpec exactly. R96 changes
  `_stablecoinToShares`'s arithmetic separately, so this PR stays byte-identical.

### Source-order and style cleanups

- **Scale immutable visibility.** `uint256 immutable i_exchangeRateDecimals;` had no visibility
  keyword. It is now `internal` (the default, stated), with a one-line `@dev`.
- **R85 slip.** [R92](./R92-feehandler-ownership.md) added the `PurchaseRbtc` constructor's `@param`
  pair as a run of `///` lines, which the [R85](./R85-natspec-delimiter.md) rule in `AGENTS.md`
  forbids.
- **Declaration order.** `DcaManager` and the lending adapters declare constants, then immutables,
  then storage in slot order. Two files break that order:
  - `PurchaseUniswap` declared two constants and an immutable between `s_mocOracle` and
    `s_amountOutMinimumPercent`. That visually splits the two fields that share one storage word.
  - `FeeHandler` declared its two constants after the fee storage.

  Constants and immutables take no storage slot, so the layout is unchanged.
- **Imports.** 48 `src/` imports were relative (`./`, `../`), and 18 in 16 files used the `src/`
  root. All are relative now.

## Open product decisions

**none** (decided 2026-09-27).

## Scope

- [x] `LendingErc20Handler`:
  - inherits `TokenHandler, ITokenLending`;
  - declares `uint256 internal immutable i_exchangeRateDecimals;` and sets it in its constructor;
  - holds `_stablecoinToShares` and `_sharesToStablecoin` unchanged, at the end of
    **INTERNAL FUNCTIONS**;
  - imports `Math`;
  - `@notice` names the conversion.
- [x] Delete `src/TokenLending.sol`.
- [x] `PurchaseRbtc` constructor NatSpec uses `/** */`.
- [x] `PurchaseUniswap` and `FeeHandler`: constants, then immutables, then storage in slot order.
- [x] Every `src/` import that used the `src/` root is relative.
- [x] Docs:
  - `AGENTS.md` layout;
  - `README.md` architecture list;
  - `src/layerbank/README.md`;
  - the `BatchTailScheduleTest` header comment;
  - the R28, R89, and `IMPLEMENTATION_ORDER.md` records that called the merge decided against;
  - R96 and R97 specs, and their order rows.

## Out of scope

- [ ] Any executable change: `mulDiv` → `ceilDiv` ([R96](./R96-ceildiv-and-one-route-class-getter.md)),
      `isLendingRoute` removal (R96), redeem-to-user ([R97](./R97-redeem-lending-exits-to-user.md)).
- [ ] Renaming `TokenLending__` errors or events.
- [ ] A shared or public exchange-rate scale (R88 stands).
- [ ] Reordering any other declaration, or any storage-layout change.

## Measured pins (2026-09-27)

This follows the metadata-stripped comparison method from [R85](./R85-natspec-delimiter.md). Every
`src/` contract with bytecode was compared against the parent (`c2ed0a7`, #160 head). That is 9
deployables, plus the `legacy-codegen` copies under `deploy`.

| Profile | Runtime | Creation |
|---|---|---|
| `default` | identical on all 9 | identical except the six lending leaves, each 2–3 B smaller: the constructor body replaces the `TokenLending(...)` base-constructor call |
| `deploy` (`via_ir`, ships) | identical on all 9 | identical on all 9 |

Under `deploy`, the `legacy-codegen` copies of `DcaManager`, `OperationsAdmin`, and
`LayerBankErc20HandlerDex` also have identical runtime. The last one's creation code is 3 B smaller, as
under `default`: it is the legacy pipeline that `[profile.deploy]` keeps only for
`LayerBankErc20HandlerDexTest`, and it never ships.

## Review disposition (2026-09-27)

This section records the review of PRs 138–160 for anything still worth doing. The review excluded items
that PRs 138–160 had already decided unless it recommended reopening them.

The bars are:
- **R87/R89:** a change that removes redundant code, checks, or reads may land at any size once its
  equivalence is proven.
- **R84:** a change that adds state, ABI, or layout needs about 1% of a batch and real money.

The human added one rule on 2026-09-27: no added complexity on rarely used user paths for small gains.

Rootstock prices here come from [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md).

| # | Candidate | Verdict | Where / why |
|---|---|---|---|
| 1 | Redeem lending exits straight to the user, instead of redeeming onto the handler and transferring | **Ship** | [R97](./R97-redeem-lending-exits-to-user.md). About −15,000 Rootstock gas per lending principal exit and −28,000 on `withdrawTokenAndInterest`. Reverses R28's PR 19 call, which was made before Rootstock pricing. |
| 2 | Merge `TokenLending` into `LendingErc20Handler` | **Ship** | This PR. Supersedes the smaller finding "move `ITokenLending` off `TokenLending`". |
| 3 | `PurchaseRbtc` constructor `///` run | **Ship** | This PR. |
| 4 | Pack the fee collector beside the fee rates and read it once per batch | **Not shipped** | At most one `SLOAD` (about 200 Rootstock) per batch, on the shipped profile only, and not measured. It costs a `FeeHandler` layout change and one more local in a fee function that has hit stack-too-deep before. [R78](./R78-flat-fee-fast-path.md) compared its layout with R77's older fee path, not with a collector-packed variant, so the question was never measured. Reopen only with a `deploy` measurement. |
| 5 | Pay principal and interest from one redemption in `withdrawTokenAndInterest` | **Rejected** | Saves one market redemption, but needs a new handler entry point and a split of one measured payout across two events. It is a rarely used user path under the human's 2026-09-27 rule, and the old front end does not call it. R97 already takes about 28,000 off this path. |
| 6 | Derive the Dex intermediate tokens from `s_swapPath` | **Rejected** | [R59](./R59-dex-path-policy.md) forbids decoding the path, and the net saving is a few hundred gas. |
| 7 | Immutable fee collector | **Rejected** | Deletes `setFeeCollectorAddress`, so the treasury could never be rotated on handlers that cannot be upgraded. That is a governance loss for about 200 per batch. |
| 8 | `Math.mulDiv(…, Ceil)` → `Math.ceilDiv(a * b, c)` in `_stablecoinToShares` | **Ship** | [R96](./R96-ceildiv-and-one-route-class-getter.md). Equivalent at every reachable input. Under `deploy`: −1,002 per 10-row lending batch and −88 B per lending leaf. |
| 9 | Tighter id packing in the batch calldata | **Rejected** | About 50 gas per row once decoding is paid for (about 0.05% of a batch). Changes the swapper's purchase ABI that invariant 9 and [R64](./R64-batch-calldata-and-schedule-keying.md) settled, and `DcaManager` would unpack the ids again for events. |
| 10 | Fold the protected-window block into `ProtocolSettings` | **Rejected** | At most one read on `updatePurchasePeriod`, a rarely used user path, possibly zero under `via_ir`. It is a layout change that the 2026-09-27 cold-path rule rules out. |
| 11 | `withdrawInterest`'s `if (stablecoinReceived > 0)` can never be false | **Ship** | R97 deletes the transfer the `if` guards. |
| 12 | `isLendingRoute` duplicates `getRouteClass` | **Ship: drop `isLendingRoute`** | [R96](./R96-ceildiv-and-one-route-class-getter.md). Initially rejected in review as ABI churn. The human reopened it as redundant code, and measurement found it saves gas too. Keep `getRouteClass`: only it separates an unregistered route from an idle one, which the deploy scripts need. |
| 13 | `i_exchangeRateDecimals` had no explicit visibility | **Ship** | This PR. |
| 14 | Mixed `src/` and relative imports | **Ship** | This PR (relative). |
| 15 | `PurchaseUniswap` declarations split the packed oracle/floor pair; `FeeHandler` constants after storage | **Ship** | This PR. |
| 16 | [R84](./R84-no-repeated-registry-reads.md)'s deposit route view, reconsidered as replacing `areDepositsPaused` with one route-struct getter | **Keep R84's decision** | It would answer R84's surface objection, and R84 measured about −1,084 per create or deposit. That is about 1% of a rarely used call for an `OperationsAdmin` ABI change. |
| 17 | Every other item decided in PRs 138–160 | **Keep** | The reasoning still holds under Rootstock pricing. The review rechecked: [R79](./R79-coalesce-repeated-buyer-writes.md) coalescing; R87's fee sweep, event trims, balance reuse, and `optimizer_runs`; R90's idle fold; R94's `BitChillOwnable` move; R59's no path decoding; [R81](./R81-one-write-per-packed-slot.md); [R86](./R86-calldata-array-parameters.md). |

## Files likely touched

- `src/LendingErc20Handler.sol`
- `src/TokenLending.sol` (deleted)
- `src/PurchaseRbtc.sol`, `src/PurchaseUniswap.sol`, `src/FeeHandler.sol`
- Imports only:
  - `src/DcaManager.sol`, `src/DcaManagerAccessControl.sol`;
  - `src/idle/`: `IdleErc20Handler`, `IdleDocHandlerMoc`, `IdleErc20HandlerDex`;
  - `src/layerbank/`, `src/sovryn/`, `src/tropykus-legacy/`: each adapter base and its `*DocHandlerMoc` and
    `*Erc20HandlerDex` leaves.
- `AGENTS.md`, `README.md`, `src/layerbank/README.md`
- `test/unit/BatchTailScheduleTest.t.sol` (comment only)
- `docs/relaunch/R95-merge-token-lending.md`, `R96-ceildiv-and-one-route-class-getter.md`,
  `R97-redeem-lending-exits-to-user.md`, `README.md`, `IMPLEMENTATION_ORDER.md`,
  `R28-lending-erc20-handler.md`, `R89-post-r88-review-candidates.md`

## Required tests

```text
forge build
FOUNDRY_PROFILE=deploy forge build
# Compare metadata-stripped runtime and creation for every src/ contract against the parent
# (R85 method; strip the CBOR tail using its trailing 2-byte length).
make check
```

Fork lanes are not required: runtime is byte-identical on both profiles, and deploy creation code is
identical too.

## Success criteria

- [x] `src/TokenLending.sol` is gone. `LendingErc20Handler is TokenHandler, ITokenLending` holds the
      scale and both helpers.
- [x] Runtime identical on every contract under both profiles; `deploy` (`via_ir`) creation identical.
- [x] `make check` green.
- [x] No `src/` import uses the `src/` root; no `///` run in `src/` outside the vendored interfaces.
- [x] Every review candidate has a verdict here.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Bytecode identity reproduced on both profiles.
- [ ] Protocol invariants in `AGENTS.md` still hold. Nothing executable changed.
- [ ] No relaunch ticket ids in `src/` comments.

## ABI / deploy / cutover impact

- ABI: none. `ITokenLending` is unchanged. `LendingErc20Handler` already exposed exactly that surface.
- Scripts: none.
- Cutover: none. No consumer references the `TokenLending` contract.
