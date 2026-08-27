# R47 — One assignment per handler address

Status: **assigned** · Assigned: yes · Optional/further-review: no

PR 34 of the relaunch stack. Stack on R46 (PR 33). Land before any new LayerBank Dex assignment and before R38 withdraw-all.

## Objective

Allow each handler address to be assigned only once in an `OperationsAdmin`, preventing two routes or tokens from sharing accounting that is keyed only by user inside the handler.

## Background

Assignments are add-only per `(token, routeIndex)`, but the same handler can currently be placed at another pair. DcaManager computes locked principal per route while lending `s_shares[user]` is per handler. If two routes share a handler, interest withdrawal on one route can treat principal locked by the other as yield and pay it out.

The invariant is broader than the known lending example: a TokenHandler instance is constructed for one stablecoin and one DcaManager, and none of its per-user accounting is route-keyed. There is no legitimate reason to reuse one address at another pair in the same admin.

## Open product decisions

**none** — one handler address may back exactly one `(token, routeIndex)` per OperationsAdmin instance.

## Scope

- [x] Track whether a handler address has already been assigned and revert a canonical custom error on reuse, regardless of token or route class.
- [x] Perform the uniqueness check in `assignTokenHandler` without weakening existing code/class/ERC-165/add-only validation.
- [x] Mark the address assigned only in the successful assignment path.
- [x] Test same token/different lending routes, same token/different idle routes, and different token/different route reuse all revert; distinct handler instances still succeed.
- [x] Add a regression showing two versioned routes with two distinct handlers preserve independent principal/share accounting.

## Out of scope

- [ ] Summing locked principal across routes as an alternative workaround.
- [ ] Reassigning, deregistering, or rescuing a mistaken handler.
- [ ] Validating live third-party protocol state beyond the existing handler interface/class checks.

## Files likely touched

- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`
- `test/unit/OperationsAdminTest.t.sol`
- A focused DcaManager/interest regression test if not cleanly expressible there

## Required tests

Run `OperationsAdminTest` plus lending interest/withdraw-all regressions, inspect storage layout, then `make check` and both fork lanes.

Commands run:

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none EXPECTED_LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC \
  forge test --match-contract "OperationsAdminTest|VersionedRouteAccountingTest"
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract VersionedRouteAccountingTest
forge inspect src/OperationsAdmin.sol:OperationsAdmin storage --force
forge build --sizes
make check
make fork-sovryn
make fork-tropykus
```

## Success criteria

- [x] One handler address cannot resolve from two pairs in one admin.
- [x] Distinct versioned handlers remain assignable at distinct indexes.
- [x] Existing add-only and route-class invariants remain intact.
- [x] No open product decisions.

## Measured results

`assignTokenHandler` now reverts `OperationsAdmin__HandlerAddressAlreadyInUse(address handler)` when the address already backs a pair. The check sits after the EOA / route-registered / pair add-only checks and **before** the ERC-165 interface and route-class checks: a reused address passed those on its first assignment, and re-running them cannot make the second pair safe. Putting it after the pair check keeps R13's `OperationsAdmin__HandlerAlreadyAssigned(token, routeIndex)` as the error when both would fire, so no existing revert changed. `s_handlerAssigned[handler] = true` is written next to `s_tokenHandler[token][routeIndex] = handler`, so a reverted assignment never consumes the address.

Uniqueness is address-scoped, not token- or class-scoped. Reuse is blocked across two lending routes, two idle routes, a second token at the same index, and lending → idle. That last case previously fell to `OperationsAdmin__LendingHandlerOnIdleRoute`; it now reports the reuse, which is the accurate reason. No function selector changed and no getter was added.

**Runtime bytecode (EIP-170 limit 24,576) vs R46:**

| contract | R46 | R47 | delta | margin after |
|---|---|---|---|---|
| `OperationsAdmin` | 4,625 | 4,850 | +225 | 19,726 |
| `DcaManager` | 16,483 | 16,483 | 0 | 8,093 |
| Handlers | unchanged | unchanged | 0 | same as R46 |

**Storage.** One appended mapping; slots `0`–`4` are untouched.

| slot | R46 | R47 |
|---|---|---|
| 0 | `_owner` | `_owner` |
| 1 | `_pendingOwner` | `_pendingOwner` |
| 2 | `s_tokenHandler` | `s_tokenHandler` |
| 3 | `s_routeClass` | `s_routeClass` |
| 4 | `s_swappers` | `s_swappers` |
| 5 | — | `s_handlerAssigned` |

**Gas.** One warm `SLOAD` on every `assignTokenHandler`, and one `SSTORE` (20,000, cold zero → non-zero) on a successful one. Owner-only deploy-time path; no user or swapper transaction touches it.

**Deploy scripts.** No change needed. `DeployMocSwaps`, `DeployDexSwaps`, `DeployIdleHandler`, `DeployLayerBankHandler`, and `DeployUsdrifHandler` each construct a fresh handler per assignment, so none of them can now revert on reuse. `VersionedRouteAccountingTest` deploys two LayerBank handlers through `DeployLayerBankHandler.deployMocksAndHandler` and proves the two routes keep independent shares, interest, and principal — the accounting property that made a shared handler unsafe. Route v1 holds 400 DOC and route v2 holds 100; with one shared handler, route v2's accrued interest would read ~400 DOC against 100 DOC of locked principal, so `assertLt(interestV2, DEPOSIT_V2)` is the assertion that fails in the shared-handler world.

The regression is Anvil-only (`block.chainid != ANVIL_CHAIN_ID` skips it). It mints DOC to the user and depends on the Pool/aToken mocks to accrue and pay yield; on a fork the stablecoin is live DOC and the mock payout path cannot mint it. The fork lanes exist for live Sovryn/MoC state, which this test does not touch. The `OperationsAdminTest` cases run on every lane.

## Reviewer checklist

- [x] Matches **Scope**; nothing from **Out of scope**.
- [x] The write cannot be bypassed through idle vs lending or a second token.
- [x] Tests in the PR match **Required tests**.
- [x] No unrelated registry refactor.

## ABI / deploy / cutover impact

- ABI: one new OperationsAdmin custom error; no function selector change.
- Scripts: each route already deploys a distinct handler; deployment tests prove that remains true.
- Cutover: ops must never reuse a handler address for another token or route.
