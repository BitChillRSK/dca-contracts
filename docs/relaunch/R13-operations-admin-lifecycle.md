# R13 — Simplify operations authority and make handler routes non-destructive

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 24. Stack on R33 (PR 23). Land before R22 deploy/CI so the final index map and deployment scripts target the final registry and authorization surface.

## Objective

Replace the redundant owner-plus-admin hierarchy with one governance owner and narrowly scoped swappers, replace the mutable string registry with direct lending-route classification, and prevent handler upgrades from redirecting live schedules away from the contracts that hold their funds.

## Background

Production has used the same multisig as both `OperationsAdmin.owner()` and `ADMIN_ROLE` for a year. The split therefore adds deployment steps and two authorization systems without creating a real trust boundary. The meaningful separation is governance versus the operational swapper bot.

The registry also has two independent correctness problems:

- `addOrUpdateLendingProtocol` can leave stale name↔index aliases when either side is reassigned;
- `assignOrUpdateTokenHandler` can overwrite a `(token, index)` route while the old handler still owns user principal, lending shares, and accumulated rBTC. Existing schedules keep only the index, so they immediately resolve to the empty new handler.

The protocol-name maps have no production consumer of their own. `DcaManager` reads the reverse map only to infer whether an index yields interest, while the forward getter is used only by tests. A route index is therefore better treated as an immutable deployment/version identifier, with a direct boolean stating whether that route lends. It is not a unique identity for an external provider: DOC can move to a new Sovryn route while USDRIF remains on an older Sovryn route without inventing on-chain names such as `sovryn-v2`.

R8 forbids an owner rescue or owner-selected migration destination. Handler upgrades must preserve each old route until users have exited or moved their own position.

## Open product decisions

- **One-shot user-migration decision:** choose either (a) add-only versioned routes with users exiting/re-entering manually, explicitly accepting that the relaunch handlers will have no cooperative migration capability, or (b) a separately testable user-initiated migration flow that measures actual cash, reconciles every affected schedule, and never lets governance choose the beneficiary. Option (b) must ship in R13 because the capability has to exist on the old immutable handler; deferring it past cutover removes that option for every handler deployed by the relaunch. There is no implicit default.

The owner/admin simplification, direct swapper authorization, removal of the string registry, direct lending-route classification, and prohibition on same-index overwrite are already decided.

## Scope

- [ ] Remove `AccessControl`, `ADMIN_ROLE`, `setAdminRole`, and `revokeAdminRole` from `OperationsAdmin`.
- [ ] Make lending-route registration, handler assignment, and swapper administration `onlyOwner`.
- [ ] Replace the role hash with a direct swapper allowlist (`mapping(address => bool)` plus `isSwapper(address)`), preserving the existing ability for multiple swappers to coexist. Rename the grant operation so it does not imply replacement; retain explicit revoke.
- [ ] Update `DcaManager.onlySwapper` to use the typed `isSwapper` query; remove its cached role hash.
- [ ] Replace the manually hashed handler key with a typed nested `token => routeIndex => handler` mapping.
- [ ] Remove the string↔index registry, `addOrUpdateLendingProtocol`, `getLendingProtocolIndex`, and `getLendingProtocolName`. Register a yielding route index directly, once; reject index zero and duplicate indexes. Expose `isLendingRoute(index)`; index `0` remains the initial idle route and always returns false.
- [ ] Keep provider labels in deployment configuration and off-chain metadata; do not rebuild an on-chain string registry solely for readability.
- [ ] Update DcaManager's interest eligibility check to call `isLendingRoute(index)` directly; no production path fetches or hashes a protocol name.
- [ ] Make handler assignment add-only for each `(token, routeIndex)`. Reassignment at the same pair reverts.
- [ ] Document and test the upgrade rule: deploy and register a new route index; old schedules and withdrawals keep resolving through the old route. Never delete the old route as part of activation.
- [ ] Treat an incorrectly classified route registration as consuming that index. Recovery is registration at a new index, not mutation of the one-shot lending classification.
- [ ] Treat an incorrectly assigned handler as consuming that route index even when it has never held funds. Recovery is registration at a new index, not a special same-index replacement path: governance cannot prove from `OperationsAdmin` that an apparently empty handler has no user position.
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
- `test/ai-generated/unit/GettersTest.t.sol`
- `test/ai-generated/unit/layerbank/LayerBankDcaManagerTest.t.sol`
- `test/unit/DcaDappTest.t.sol`
- `test/unit/deployment/IdleHandlerDeploymentTest.t.sol`
- `test/unit/deployment/LayerBankHandlerDeploymentTest.t.sol`
- `script/DeployMocSwaps.s.sol`
- `script/DeployDexSwaps.s.sol`
- `script/DeployIdleHandler.s.sol`
- `script/DeployLayerBankHandler.s.sol`
- `script/DeployUsdrifHandler.s.sol`
- Every additional checked-in caller of the removed registry functions, selected through compiler errors. This includes `test/unit/deployment/BaseDeploymentTest.t.sol`, `test/ai-generated/unit/HandlerTestHarness.t.sol`, `test/ai-generated/fuzz/Invariants.t.sol`, `test/ComparePurchaseMethods.t.sol`, and all six per-handler suites; updating them is required scope, not a drive-by expansion.

## Required tests

```sh
forge test --match-contract OperationsAdminTest
forge test --match-contract RoleSecurityTest
forge test --match-contract GettersTest
forge test --match-contract DcaManagerEdgeCasesTest
forge test --match-contract "IdleHandlerDeploymentTest|LayerBankHandlerDeploymentTest"
make check
make fork-sovryn
make fork-tropykus
```

Assert that only the owner can register lending routes and administer swappers; the existing multi-swapper behavior is preserved; revoked swappers cannot purchase; deployment transfers final ownership to the configured governance address; index zero and duplicate lending-route registrations revert; mistaken route classification and mistaken handler assignment are both recovered only at new indexes; duplicate handler routes revert even before use; old and new versioned routes remain independently resolvable; and the selected user-migration policy cannot redirect funds to governance.

Fork tests add no new fork-specific assertions unless the selected migration design requires a live-protocol redemption proof.

## Success criteria

- [ ] One governance authority exists: `owner`; there is no `ADMIN_ROLE` or generic `hasRole` surface.
- [ ] Swapper authority is a narrow explicit allowlist, supports multiple addresses, and is independently revocable.
- [ ] No protocol-name registry or stale forward/reverse alias can exist; lending eligibility is a direct route property.
- [ ] Lending classification and `(token, routeIndex)` handler assignment are both immutable once registered.
- [ ] Handler upgrades preserve access to the old handler and its user accounting.
- [ ] The one-shot migration gate is answered: cooperative user migration ships now, or the relaunch explicitly commits these handler versions to manual user exit/re-entry.
- [ ] No protocol invariant changes.
- [ ] Targeted, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests cover authority boundaries, string-registry removal, duplicate route rejection, route immutability, and upgrade continuity.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No owner-directed migration or silent replacement path exists.

## ABI / deploy / cutover impact

- ABI: removes AccessControl/admin-role functions and constants plus the string protocol registry/getters; adds typed owner/swapper, lending-route status, and add-only route functions. Exact selectors belong in the implementation PR after the migration gate is answered.
- Scripts: all deployment and add-on scripts must use the owner-governed API. No broadcast in this PR.
- Cutover: fresh relaunch deployment. Governance must use a new route index for every later handler version and retain old route entries for exits. If cooperative migration is not selected now, it is unavailable to the immutable handlers deployed at cutover.
