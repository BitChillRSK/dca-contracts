# R47 — One assignment per handler address

Status: **not started** · Assigned: no · Optional/further-review: no

PR 34 of the relaunch stack. Stack on R46 (PR 33). Land before any new LayerBank Dex assignment and before R38 withdraw-all.

## Objective

Allow each handler address to be assigned only once in an `OperationsAdmin`, preventing two routes or tokens from sharing accounting that is keyed only by user inside the handler.

## Background

Assignments are add-only per `(token, routeIndex)`, but the same handler can currently be placed at another pair. DcaManager computes locked principal per route while lending `s_shares[user]` is per handler. If two routes share a handler, interest withdrawal on one route can treat principal locked by the other as yield and pay it out.

The invariant is broader than the known lending example: a TokenHandler instance is constructed for one stablecoin and one DcaManager, and none of its per-user accounting is route-keyed. There is no legitimate reason to reuse one address at another pair in the same admin.

## Open product decisions

**none** — one handler address may back exactly one `(token, routeIndex)` per OperationsAdmin instance.

## Scope

- [ ] Track whether a handler address has already been assigned and revert a canonical custom error on reuse, regardless of token or route class.
- [ ] Perform the uniqueness check in `assignTokenHandler` without weakening existing code/class/ERC-165/add-only validation.
- [ ] Mark the address assigned only in the successful assignment path.
- [ ] Test same token/different lending routes, same token/different idle routes, and different token/different route reuse all revert; distinct handler instances still succeed.
- [ ] Add a regression showing two versioned routes with two distinct handlers preserve independent principal/share accounting.

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

## Success criteria

- [ ] One handler address cannot resolve from two pairs in one admin.
- [ ] Distinct versioned handlers remain assignable at distinct indexes.
- [ ] Existing add-only and route-class invariants remain intact.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] The write cannot be bypassed through idle vs lending or a second token.
- [ ] Tests in the PR match **Required tests**.
- [ ] No unrelated registry refactor.

## ABI / deploy / cutover impact

- ABI: one new OperationsAdmin custom error; no function selector change.
- Scripts: each route already deploys a distinct handler; deployment tests prove that remains true.
- Cutover: ops must never reuse a handler address for another token or route.
