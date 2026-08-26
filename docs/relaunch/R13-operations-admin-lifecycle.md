# R13 — Simplify operations authority and make handler routes non-destructive

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 23. Stack on the post-R30 planning PR (PR 22, GitHub #66). Land before R22 deploy/CI so the final index map and deployment scripts target the final registry and authorization surface.

## Objective

Replace the redundant owner-plus-admin hierarchy with one governance owner and narrowly scoped swappers, make protocol registration canonical, and prevent handler upgrades from redirecting live schedules away from the contracts that hold their funds.

## Background

Production has used the same multisig as both `OperationsAdmin.owner()` and `ADMIN_ROLE` for a year. The split therefore adds deployment steps and two authorization systems without creating a real trust boundary. The meaningful separation is governance versus the operational swapper bot.

The registry also has two independent correctness problems:

- `addOrUpdateLendingProtocol` can leave stale name↔index aliases when either side is reassigned;
- `assignOrUpdateTokenHandler` can overwrite a `(token, index)` route while the old handler still owns user principal, lending shares, and accumulated rBTC. Existing schedules keep only the index, so they immediately resolve to the empty new handler.

R8 forbids an owner rescue or owner-selected migration destination. Handler upgrades must preserve each old route until users have exited or moved their own position.

## Open product decisions

- **User-authorized migration:** choose either (a) add-only versioned routes with users exiting/re-entering manually, or (b) a separately testable user-initiated migration flow that measures actual cash, reconciles every affected schedule, and never lets governance choose the beneficiary. Recommended default: ship versioned routes in R13 and defer automated migration unless its accounting can be fully specified before implementation.

The owner/admin simplification, direct swapper authorization, canonical registry, and prohibition on same-index overwrite are already decided.

## Scope

- [ ] Remove `AccessControl`, `ADMIN_ROLE`, `setAdminRole`, and `revokeAdminRole` from `OperationsAdmin`.
- [ ] Make protocol registration, handler assignment, and swapper administration `onlyOwner`.
- [ ] Replace the role hash with direct multi-swapper authorization (`mapping(address => bool)` plus `isSwapper(address)`). Rename the grant operation so it does not imply replacement; retain explicit revoke.
- [ ] Update `DcaManager.onlySwapper` to use the typed `isSwapper` query; remove its cached role hash.
- [ ] Replace the manually hashed handler key with a typed nested `token => routeIndex => handler` mapping.
- [ ] Make protocol/index registration canonical and reject empty names, index zero for yielding protocols, duplicate names, and duplicate indexes. Expose a direct `isLendingProtocol(index)` query; index `0` remains the initial idle route.
- [ ] Make handler assignment add-only for each `(token, routeIndex)`. Reassignment at the same pair reverts.
- [ ] Document and test the upgrade rule: deploy and register a new route index; old schedules and withdrawals keep resolving through the old route. Never delete the old route as part of activation.
- [ ] Preserve contract-code and ERC-165 handler attestation, using `handler.code.length` instead of importing `Address` if the final implementation does not need that library.
- [ ] Apply the recorded migration decision without weakening balance-delta cash accounting or signer-only rBTC withdrawal.
- [ ] Update deploy helpers, add-on scripts, interfaces, role/registry tests, DcaManager tests, and mocks for the final API. Deployment must leave the intended governance multisig as `owner`, not the broadcaster or an obsolete admin role. Do not broadcast.

## Out of scope

- [ ] Owner/admin movement of another user's principal, shares, stablecoin, or rBTC.
- [ ] Silent or explicit same-index handler overwrite.
- [ ] Proxies, delegatecall, owner rescue, arbitrary migration destinations, or a withdrawal `to` parameter.
- [ ] R31 handler selector pruning, R32 internal cleanup, R33 slippage validation, R34 DcaManager ABI cleanup, R9 events, or R22's final production index map.
- [ ] Pausing, external incentives, fee policy, or protocol-specific lending changes.

## Files likely touched

- `src/OperationsAdmin.sol`
- `src/interfaces/IOperationsAdmin.sol`
- `src/DcaManager.sol`
- `test/unit/OperationsAdminTest.t.sol`
- `test/ai-generated/unit/RoleSecurityTest.t.sol`
- `test/unit/DcaDappTest.t.sol`
- `script/DeployMocSwaps.s.sol`
- `script/DeployDexSwaps.s.sol`
- `script/DeployIdleHandler.s.sol`
- `script/DeployLayerBankHandler.s.sol`
- `script/DeployUsdrifHandler.s.sol`

## Required tests

```sh
forge test --match-contract OperationsAdminTest
forge test --match-contract RoleSecurityTest
forge test --match-contract DcaManagerEdgeCasesTest
make check
make fork-sovryn
make fork-tropykus
```

Assert that only the owner can register protocols/routes and administer swappers; multiple swappers can coexist; revoked swappers cannot purchase; deployment transfers final ownership to the configured governance address; duplicate protocol names/indexes and duplicate handler routes revert; old and new versioned routes remain independently resolvable; and the selected user-migration policy cannot redirect funds to governance.

Fork tests add no new fork-specific assertions unless the selected migration design requires a live-protocol redemption proof.

## Success criteria

- [ ] One governance authority exists: `owner`; there is no `ADMIN_ROLE` or generic `hasRole` surface.
- [ ] Swapper authority is a narrow explicit allowlist, supports multiple addresses, and is independently revocable.
- [ ] Protocol identity cannot develop stale forward/reverse aliases.
- [ ] A live `(token, routeIndex)` cannot be overwritten.
- [ ] Handler upgrades preserve access to the old handler and its user accounting.
- [ ] The migration gate is recorded and fully implemented or explicitly deferred to manual user exit/re-entry.
- [ ] No protocol invariant changes.
- [ ] Targeted, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests cover authority boundaries, alias rejection, route immutability, and upgrade continuity.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No owner-directed migration or silent replacement path exists.

## ABI / deploy / cutover impact

- ABI: removes AccessControl/admin-role functions and constants; adds typed owner/swapper, protocol-status, and add-only route functions. Exact selectors belong in the implementation PR after the migration gate is answered.
- Scripts: all deployment and add-on scripts must use the owner-governed API. No broadcast in this PR.
- Cutover: fresh relaunch deployment. Governance must use a new route index for every later handler version and retain old route entries for exits.
