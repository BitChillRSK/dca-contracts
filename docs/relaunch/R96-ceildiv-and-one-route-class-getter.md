# R96 — `ceilDiv` share conversion and one route-class getter

Status: **implemented** · GitHub [#162](https://github.com/BitChillRSK/dca-contracts/pull/162) · Assigned: yes · Optional/further-review: no · Stack on: R95 ([#161](https://github.com/BitChillRSK/dca-contracts/pull/161))

## Objective

This PR makes two gas and redundancy edits, each proven equivalent at every reachable input:

1. `LendingHandler._stablecoinToShares` computes
   `Math.ceilDiv(stablecoinAmount * i_exchangeRateDecimals, exchangeRate)` instead of
   `Math.mulDiv(stablecoinAmount, i_exchangeRateDecimals, exchangeRate, Math.Rounding.Ceil)`.
2. `OperationsAdmin.isLendingRoute` is deleted. It returns `getRouteClass(i) == Lending`, and its
   one production caller, `DcaManager._tokenYieldsInterest`, now makes that comparison itself, and is
   renamed `_isLendingRoute`. Its reverting twin `_checkTokenYieldsInterest` becomes `_checkTokenIsLent`,
   and the error it raises, `DcaManager__TokenDoesNotYieldInterest`, becomes `DcaManager__TokenIsNotLent`.

## Background

Both items come from the 2026-09-27 review of PRs 138–160 (see
[R95 **Review disposition**](./R95-merge-token-lending.md#review-disposition-2026-09-27), items 8 and
12). They meet the [R87](./R87-deferred-gas-candidates.md)/[R89](./R89-post-r88-review-candidates.md)
bar: remove redundant work at any size, once equivalence is proven.

### `ceilDiv`

OpenZeppelin's rounded `mulDiv` computes a 512-bit product and then runs `mulmod` for the rounding
bit. When the 256-bit product `stablecoinAmount * scale` does not overflow, it returns exactly
`ceilDiv(stablecoinAmount * scale, exchangeRate)`:
- **Zero numerator:** both return 0.
- **Positive numerator:** `(p − 1) / r + 1 = ⌈p / r⌉`.
- **Zero rate:** both panic `0x12`.

The one difference is a product above `2^256 − 1`. `mulDiv` would still divide, while the checked
multiply panics `0x11`. That input is unreachable:

| Caller | Bound on `stablecoinAmount` | Largest product |
|---|---|---|
| `_batchRetrieveStablecoin` | a schedule's `uint96 purchaseAmount` | `2^96 × 1e27 < 2^186` (LayerBank RAY is the largest scale) |
| `_redeemShares` via `_withdrawToken` | clamped to `_sharesToStablecoin(shares, rate) = shares × rate / scale` before the conversion | `≤ shares × rate`, a product already computed checked, so `< 2^256` |
| `_redeemShares` via `withdrawInterest` | `total − locked`, where `total = shares × rate / scale` | same bound |

If a future caller ever passes an amount whose product with the scale overflows, the call reverts; it does
not wrap. That matches R89's rule that market-sourced arithmetic stays checked.

### One route-class getter

`OperationsAdmin` stores one fact per route index: its `RouteClass`. Two views read it:
- `isLendingRoute(i)`, which is `getRouteClass(i) == RouteClass.Lending`;
- `getRouteClass(i)`.

Only `getRouteClass` separates an unregistered index from an idle one, and the deploy scripts and the
`README.md` runbook rely on that: they call `registerRoute` only while the class is `Unregistered`. So
`getRouteClass` stays. [R13](./R13-operations-admin-lifecycle.md)'s sketch had only `isLendingRoute`.
`getRouteClass` was added in the same commit for operators, and no spec decided to keep both.

`isLendingRoute` has one production caller, `DcaManager._tokenYieldsInterest`. That function gates
`withdrawTokenAndInterest`, `topUpFromInterest`, `withdrawAllAccumulatedInterest` (once per pair), and
`getInterestAccrued`.

The review first rejected removing it as ABI churn. The human reopened it on 2026-09-27 as redundant
code, and measurement then showed it is cheaper too.

### Naming the private helper

The human asked on 2026-09-27 whether `_tokenYieldsInterest` should become `_tokenIsLent` or
`_isTokenLent`. The `is…` prefix is the right form for a boolean. The subject, though, is the route:
the function takes a route index, ignores the token, and asks `OperationsAdmin` for the route's class.
So it is `_isLendingRoute(routeIndex)`, the same question the deleted external view answered, now asked
privately.

The reverting form takes the token and reports it, so it is named for what the user is told:
`_checkTokenIsLent(token, routeIndex)` reverts `DcaManager__TokenIsNotLent(token)`. The human renamed the
error on 2026-09-27. `TokenDoesNotYieldInterest` read as a property of the asset, as if DOC were being
told apart from a yield-bearing stablecoin such as USDe. What it actually reports is that this schedule's
route does not lend the token. The rename changes only the error selector
(`0xa92cfdc4` → `0x9f87d123`). With that one substitution, `DcaManager`'s runtime and creation bytecode
are identical on both profiles, and every other contract is byte-identical.

### Prototype measurements (2026-09-27)

These are Foundry gas figures from throwaway worktrees. Both edits are pure computation with the same
storage reads, so they carry over 1:1 to Rootstock. The implementation re-measures them on this branch
(**Measured pins**).

| Edit | Profile | Gas | Runtime |
|---|---|---|---|
| `ceilDiv` | `deploy` | −1,002 per 10-row lending batch; −102 per lending withdrawal (−204 on `withdrawTokenAndInterest`) | −88 B per lending leaf |
| `ceilDiv` | `default` | −4,230 per 10-row lending batch; −423 per lending withdrawal | — |
| Drop `isLendingRoute` | `deploy` | −217 per interest-route check; −22 per purchase batch (cheaper `isSwapper` dispatch) | `OperationsAdmin` −83 B, `DcaManager` +64 B |
| Drop `isLendingRoute` | `default` | −62 per interest-route check | `OperationsAdmin` −94 B, `DcaManager` +75 B |

`DcaManager` grows because it now ABI-decodes and range-checks an enum instead of a `bool`.

## Measured pins (2026-09-27)

These are measured on this branch against its parent R95 (`b16e9c8`) on the MoC Sovryn and LayerBank
lanes, per test, with `--fuzz-seed 1`. Every changed test is cheaper, and the two lanes agree. Nothing
reads or writes storage differently, so each delta carries over 1:1 to Rootstock.

| Test | `default` | `deploy` (ships) |
|---|---:|---:|
| `testSinglePurchase` (one lending row) | −423 | −115 |
| `testBatchPurchasesOneUser` | −4,653 | −1,140 |
| `R89ReviewCandidatesGasTest.test_withdrawToken_readsBookedSharesOnce` | −402 | −242 |
| `StablecoinLendingTest.testWithdrawInterest` | −609 | −753 |
| `StablecoinLendingTest.testWithdrawTokenAndInterest` | −1,032 | −855 |
| `GettersTest.test_operationsAdmin_isSwapper` | — | −66 |

Under `deploy`, the mechanisms are:
- `ceilDiv` saves about 93 per converted lending row and about 100 per exit conversion.
- Each interest-route check saves about 217.
- `OperationsAdmin`'s smaller dispatcher saves 22 per `isSwapper` call, so every batch is 22 cheaper
  on every route, idle included.

Runtime size in bytes:

| Contract | `default` | `deploy` |
|---|---:|---:|
| Each lending leaf (Sovryn, LayerBank, Tropykus; MoC and Dex) | −298 | −88 |
| `OperationsAdmin` | −94 (3,339 → 3,245) | −83 (2,603 → 2,520) |
| `DcaManager` | +75 (13,206 → 13,281) | +64 (11,447 → 11,511) |

The idle leaves are byte-identical.

The consumer check found no caller. GitHub code search over every `BitChillRSK` repository finds no
`isLendingRoute` or `getRouteClass` outside this repo. The same search does find the old front end's
`withdrawAllAccumulatedInterest`, so the index covers the consumer repos.

## Open product decisions

**none** (decided 2026-09-27).

## Scope

- [x] `_stablecoinToShares` uses `Math.ceilDiv(stablecoinAmount * i_exchangeRateDecimals, exchangeRate)`.
      Its `@dev` states the reachable bound and that an overflow reverts.
- [x] Delete `isLendingRoute` from `IOperationsAdmin` and `OperationsAdmin`.
      `DcaManager._tokenYieldsInterest`, renamed `_isLendingRoute`, returns
      `i_operationsAdmin.getRouteClass(routeIndex) == IOperationsAdmin.RouteClass.Lending`;
      `_checkTokenYieldsInterest` becomes `_checkTokenIsLent`.
- [x] Rename `DcaManager__TokenDoesNotYieldInterest(address)` to `DcaManager__TokenIsNotLent(address)`.
- [x] Tests:
  - Delete `isLendingRoute` assertions that duplicate an adjacent `getRouteClass` assertion.
  - Convert the rest to `getRouteClass` with the exact class (`Idle` or `Unregistered`, not
    "not lending").
  - Point R38's call-count test at `getRouteClass`.
  - Add a conversion test: a fuzzed equivalence with rounded `mulDiv` over the reachable domain,
    and a pin that a product overflow panics `0x11`.

## Out of scope

- [ ] Changing `_sharesToStablecoin`, or any other `mulDiv` site.
- [ ] Any other `OperationsAdmin` view. R84 keeps `getTokenHandler` and `areDepositsPaused` separate.

## Files likely touched

- `src/LendingHandler.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`, `src/DcaManager.sol`
- Tests that call `isLendingRoute`:
  - `test/unit/`: `OperationsAdminTest`, `WithdrawAllRoutePairsTest`,
    `deployment/IdleHandlerDeploymentTest`, `deployment/NewHandlerDeploymentTest`,
    `deployment/LayerBankHandlerDeploymentTest`;
  - `test/gas/R89ReviewCandidatesGas`;
  - `test/ai-generated/unit/`: `GettersTest`, `RoleSecurityTest`, `idle/IdleDcaManagerTest`,
    `layerbank/LayerBankDcaManagerTest`.
- The conversion test's home: `test/unit/LendingHandlerRedeemTest.t.sol`'s harness exposes the helper.
- `docs/relaunch/R96-ceildiv-and-one-route-class-getter.md`, `README.md`, `IMPLEMENTATION_ORDER.md`

## Required tests

```text
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/LendingHandlerRedeemTest.t.sol -vv
make check
make fork-sovryn
make fork-tropykus
```

Gas pins are measured under both profiles on the MoC/Sovryn lane, comparing this branch against its
parent per test.

## Success criteria

- [x] Conversion equivalence fuzzed; overflow pin green.
- [x] No `isLendingRoute` or `TokenDoesNotYieldInterest` left in `src/`, `test/`, or `script/`.
- [x] Gas and size pins recorded under both profiles.
- [x] `make check` and the fork lanes green.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] The overflow bound holds for every `_stablecoinToShares` caller.
- [ ] Converted test assertions are at least as strict as before.
- [ ] Protocol invariants in `AGENTS.md` still hold.

## ABI / deploy / cutover impact

- ABI: `OperationsAdmin.isLendingRoute(uint256)` (selector `0xb021edc6`) is removed.
  `DcaManager__TokenDoesNotYieldInterest(address)` (`0xa92cfdc4`) becomes `DcaManager__TokenIsNotLent(address)`
  (`0x9f87d123`). No event changes.
- Scripts: none. The scripts already use `getRouteClass`.
- Cutover:
  - No consumer calls `isLendingRoute`.
  - The front end decodes the old error name and maps it to a friendly message:
    [front-end#27](https://github.com/BitChillRSK/front-end/issues/27).
  - `swapper-bot` and `bitchill-monitoring` carry the name only in a stale `abi.json` and never hit this
    revert. Their pending ABI regenerations pick it up.
