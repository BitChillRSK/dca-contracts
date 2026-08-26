# R13 — Simplify operations authority and make handler routes non-destructive

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 24, GitHub [#68](https://github.com/BitChillRSK/dca-contracts/pull/68). Stack on R33 (PR 23). Land before R22 deploy/CI so the final index map and deployment scripts target the final registry and authorization surface.

## Objective

Replace the redundant owner-plus-admin hierarchy with one governance owner and narrowly scoped swappers, replace the mutable string registry with direct lending-route classification, and prevent handler upgrades from redirecting live schedules away from the contracts that hold their funds.

## Background

Production has used the same multisig as both `OperationsAdmin.owner()` and `ADMIN_ROLE` for a year. The split therefore adds deployment steps and two authorization systems without creating a real trust boundary. The meaningful separation is governance versus the operational swapper bot.

The registry also has two independent correctness problems:

- `addOrUpdateLendingProtocol` can leave stale name↔index aliases when either side is reassigned;
- `assignOrUpdateTokenHandler` can overwrite a `(token, index)` route while the old handler still owns user principal, lending shares, and accumulated rBTC. Existing schedules keep only the index, so they immediately resolve to the empty new handler.

The protocol-name maps have no production consumer of their own. `DcaManager` reads the reverse map only to infer whether an index yields interest, while the forward getter is used only by tests. A route index is therefore better treated as an immutable deployment/version identifier carrying its own recorded class — idle or lending — rather than one inferred from registry emptiness (**Decision — idle is a route class, not index zero** explains why the inferred form makes a buggy idle handler unrecoverable). It is not a unique identity for an external provider: DOC can move to a new Sovryn route while USDRIF remains on an older Sovryn route without inventing on-chain names such as `sovryn-v2`.

R8 forbids an owner rescue or owner-selected migration destination. Handler upgrades must preserve each old route until users have exited or moved their own position.

## Open product decisions

**none** · The one-shot user-migration gate was answered on 2026-08-26 — see **Decision — manual exit/re-entry (option a)**. Do not ask it again; implement.

The owner/admin simplification, direct swapper authorization, removal of the string registry, direct lending-route classification, and prohibition on same-index overwrite were already decided.

## Decision — manual exit/re-entry (option a)

Recorded 2026-08-26. The relaunch ships **add-only versioned routes with no cooperative migration**. A user leaves a handler through the existing withdrawal path and opens a new schedule at the new route index. These handler versions will never gain a migration hook, and that is accepted deliberately.

**1. Cooperative migration is a UX feature, not a safety feature.** It does not help in the scenarios that motivate it:

| Failure | Does migration help? |
| --- | --- |
| Handler share-accounting bug, redeem broken | **No.** Migration redeems through the same `LendingErc20Handler` clamp path. If redeem is broken, migration is broken. |
| Lending market degrades (Tropykus paused kDOC mint between blocks 8739512 and 8740674) | **No.** Same redemption dependency; if only mint is paused, ordinary withdrawal already works. |
| Purchase-path bug (Uniswap, MoC) | **No urgency.** Principal stays fully withdrawable; nothing is trapped. |
| Governance wants users on a better lending route | **Yes** — saves a round trip through the user's wallet. A convenience upgrade, not an emergency. |

The escape hatch the pluggable-handler architecture was built for is `withdrawTokenAndInterest`, which already exists and is the most-tested path in the protocol.

**2. The Dex handlers cannot fit it.** Measured with `forge build --sizes` at `eb0c38b`:

```
SovrynErc20HandlerDex     24,150 B   runtime margin: 426 B
TropykusErc20HandlerDex   24,273 B   runtime margin: 303 B
```

`SovrynErc20HandlerDex` is a relaunch handler, so its 426 bytes are binding (Tropykus is legacy and is not redeployed). A source-side migration needs redeem-all, share-balance zeroing, a registry-validated transfer to the destination, a destination-side pull that measures its own balance delta, plus errors, events, and `DcaManager` reconciliation of every affected schedule under `nonReentrant`. That does not fit. R31 is budgeted to recover headroom, not to fund a new feature.

**3. It would be the highest-value target in the protocol, on immutable contracts.** A function whose job is moving an entire user position from contract A to contract B is the worst place for an unaudited bug that can never be patched. The multi-step reconciliation — redeem all, zero shares, credit on the new handler, rewrite N schedules across possibly several tokens — is exactly the shape where an off-by-one strands shares or double-credits. Shipping option (b) wrong is strictly worse than not shipping it.

**4. The one-shot framing is narrower than it appears.** Migration needs the source hook on the *old* handler, so handler generation 2 can ship it and support v2→v3 moves; the protocol is not permanently locked out. The real cost is that the v1 relaunch cohort performs one manual exit, ever — and the relaunch is a fresh deployment, so every current production user performs that exit at cutover regardless.

**Accepted cost.** Some users will not return after a withdraw/redeposit cycle. This is bounded: old routes stay registered forever, so users who do not move keep DCA-ing on the old route with no deadline and no breakage, and R15's `type(uint256).max` sentinel plus signer-only rBTC withdrawal already reduce a full exit to a short guided frontend flow.

### Conditions attached to this decision

- [x] `OperationsAdmin` natspec and this spec state that route registration is add-only and old routes are **never** deregistered. That guarantee is the entire user-exit story.
- [x] A test proves old and new route indexes stay independently resolvable for withdrawals after a new handler is registered at a new index.
- [x] The **ABI / deploy / cutover impact** section records that a future handler generation may ship the source-side migration hook, so this is not a permanent protocol commitment.
- [x] Nothing else moves: no owner-chosen destination, no withdrawal `to` parameter, no rescue. R8 and `AGENTS.md` invariant 3 hold unchanged.

## Decision — idle is a route class, not index zero

Recorded 2026-08-26, together with the migration gate. The two interact: add-only assignment plus a single idle slot per token would make a buggy idle handler unrecoverable.

Today "idle" and "index 0" are welded together by the string registry, not by design. `OperationsAdmin:46` rejects any non-zero index with no registered protocol name, and `DcaManager:645` infers interest eligibility from that same name being non-empty. There are therefore exactly two classes: index `0` with no name (idle) and a named index (lending). An idle handler has nowhere else to live, so once `(token, 0)` is assigned under the add-only rule it is consumed forever.

If the idle handler then turns out to have a bug:

- **Existing idle users are unaffected by any redeployment.** Their stablecoin sits in the handler, and R8 forbids owner rescue, so redeploying `DcaManager`, `OperationsAdmin`, and every handler rescues nobody. Their recourse is withdrawal, exactly as in any handler-bug scenario.
- **New users wanting an idle route on that token are stuck.** `(token, 0)` is spent and no non-zero index accepts a non-lending handler. The only escapes would be registering the fixed idle handler as a lending route — which points `withdrawTokenAndInterest` and `withdrawAllAccumulatedInterest` at a handler that does not implement `ITokenLending` — or redeploying. Both are unacceptable.

Therefore route indexes carry an explicit one-shot class instead of inferring it from registry emptiness:

```solidity
enum RouteClass { Unregistered, Idle, Lending }
mapping(uint256 routeIndex => RouteClass) private s_routeClass;

constructor() Ownable() { s_routeClass[0] = RouteClass.Idle; }   // default idle route

function registerRoute(uint256 index, bool lends) external onlyOwner {
    if (s_routeClass[index] != RouteClass.Unregistered) revert OperationsAdmin__RouteAlreadyRegistered(index);
    s_routeClass[index] = lends ? RouteClass.Lending : RouteClass.Idle;
}

function isLendingRoute(uint256 index) external view returns (bool) {
    return s_routeClass[index] == RouteClass.Lending;
}
```

Handler assignment then requires a registered class, and a buggy idle handler is recovered exactly like a buggy lending handler: register a new index as idle, assign the fixed handler there, and old schedules keep resolving to the old handler for exits. No relaunch and no special case. Everything else in this spec is unchanged — one-shot classification, add-only `(token, routeIndex)` assignment, no same-index overwrite.

Two side effects, both wanted:

- Requiring a registered class preserves today's typo protection at `OperationsAdmin:46`. If unregistered indexes merely defaulted to "not lending", a fat-fingered index in handler assignment would silently create a live non-yielding route instead of reverting.
- Index `0` becomes unremarkable — the route the constructor happens to pre-register — which is easier to reason about than a magic value.

The exact names (`registerRoute`, `RouteClass`, the enum-versus-two-booleans choice) are the implementer's call; the required properties are one-shot classification per index, idle permitted at any registered idle index, assignment rejecting unregistered indexes, and `isLendingRoute` reading recorded state.

## Noted, not in scope: `setOperationsAdmin`

`DcaManager.setOperationsAdmin` (`DcaManager:430`) is `onlyOwner` and unrestricted, so governance can swap the entire route map in one call and re-point every live schedule at whatever a fresh `OperationsAdmin` says. It is the largest remaining surface through which governance could redirect live schedules, and it is a theoretical recovery path for the idle problem above — but one omitted re-registration strands a token's users, so nothing in this spec may design around it.

Do not change, constrain, or remove it in R13. It is recorded here so the next planning pass can decide whether it becomes one-shot or is dropped after deployment.

## Scope

- [x] Remove `AccessControl`, `ADMIN_ROLE`, `setAdminRole`, and `revokeAdminRole` from `OperationsAdmin`.
- [x] Make lending-route registration, handler assignment, and swapper administration `onlyOwner`.
- [x] Replace the role hash with a direct swapper allowlist (`mapping(address => bool)` plus `isSwapper(address)`), preserving the existing ability for multiple swappers to coexist. Rename the grant operation so it does not imply replacement; retain explicit revoke.
- [x] Update `DcaManager.onlySwapper` to use the typed `isSwapper` query; remove its cached role hash.
- [x] Replace the manually hashed handler key with a typed nested `token => routeIndex => handler` mapping.
- [x] Remove the string↔index registry, `addOrUpdateLendingProtocol`, `getLendingProtocolIndex`, and `getLendingProtocolName`. Replace them with an explicit one-shot route-class registry (see **Decision — idle is a route class, not index zero**): each index is registered once as idle or lending, the constructor pre-registers index `0` as idle, re-registration of any index reverts, and `isLendingRoute(index)` reads the recorded class.
- [x] Permit idle handlers at any registered idle index, not only index `0`, so a buggy idle handler is recovered the same way as a buggy lending handler.
- [x] Require a registered route class in handler assignment: assigning at an unregistered index reverts. This preserves the protection at `OperationsAdmin:46` against a mistyped index silently creating a live route.
- [x] Keep provider labels in deployment configuration and off-chain metadata; do not rebuild an on-chain string registry solely for readability.
- [x] Update DcaManager's interest eligibility check to call `isLendingRoute(index)` directly; no production path fetches or hashes a protocol name.
- [x] Make handler assignment add-only for each `(token, routeIndex)`. Reassignment at the same pair reverts.
- [x] Document and test the upgrade rule: deploy and register a new route index; old schedules and withdrawals keep resolving through the old route. Never delete the old route as part of activation.
- [x] Treat an incorrectly classified route registration as consuming that index. Recovery is registration at a new index, not mutation of the one-shot lending classification.
- [x] Treat an incorrectly assigned handler as consuming that route index even when it has never held funds. Recovery is registration at a new index, not a special same-index replacement path: governance cannot prove from `OperationsAdmin` that an apparently empty handler has no user position.
- [x] Preserve contract-code and ERC-165 handler attestation, using `handler.code.length` instead of importing `Address` if the final implementation does not need that library.
- [x] Apply the recorded migration decision — **option (a), manual exit/re-entry** — without weakening balance-delta cash accounting or signer-only rBTC withdrawal. In practice this means adding no migration code at all; the work is the four **Conditions attached to this decision**.
- [x] State the add-only, never-deregistered route guarantee in `OperationsAdmin` natspec, not only in this spec.
- [x] Update deploy helpers, add-on scripts, interfaces, role/registry tests, DcaManager tests, and mocks for the final API. Deployment must leave the intended governance multisig as `owner`, not the broadcaster or an obsolete admin role. Do not broadcast.

## Out of scope

- [ ] Cooperative, user-initiated, or governance-directed migration in any form, including a destination-side accept hook. Settled by **Decision — manual exit/re-entry (option a)**; do not reopen it.
- [ ] Changing, constraining, or removing `DcaManager.setOperationsAdmin` (see **Noted, not in scope: `setOperationsAdmin`**).
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

Assert that only the owner can register routes and administer swappers; the existing multi-swapper behavior is preserved; revoked swappers cannot purchase; and deployment transfers final ownership to the configured governance address.

Route registry and lifecycle:

- Re-registering any index reverts, including index `0`, which the constructor pre-registers as idle.
- `isLendingRoute` returns false for idle and unregistered indexes and true only for indexes registered as lending.
- Assigning a handler at an unregistered index reverts.
- Duplicate `(token, routeIndex)` handler assignment reverts even before the route has held funds.
- Mistaken route classification and mistaken handler assignment are both recovered only at new indexes.
- An idle handler registers and resolves at a **non-zero** idle index, and a second idle route for the same token leaves the original `(token, 0)` route independently resolvable.

Migration policy (option a):

- After a new handler is registered at a new index, withdrawals through the **old** index still resolve to the old handler and pay the user — the condition-2 continuity proof.
- No code path lets any caller, owner included, move another account's principal, shares, stablecoin, or rBTC.

Fork tests add no new fork-specific assertions unless the selected migration design requires a live-protocol redemption proof.

## Success criteria

- [x] One governance authority exists: `owner`; there is no `ADMIN_ROLE` or generic `hasRole` surface.
- [x] Swapper authority is a narrow explicit allowlist, supports multiple addresses, and is independently revocable.
- [x] No protocol-name registry or stale forward/reverse alias can exist; lending eligibility is a direct route property.
- [x] Route classification and `(token, routeIndex)` handler assignment are both immutable once registered.
- [x] A route index carries an explicit idle-or-lending class; idle is not welded to index `0`, and an idle route can be re-established at a new index without redeploying the protocol.
- [x] Handler upgrades preserve access to the old handler and its user accounting.
- [x] The one-shot migration gate is closed as **option (a)**: the relaunch commits these handler versions to manual user exit/re-entry, and all four attached conditions are met.
- [x] No protocol invariant changes.
- [x] Targeted, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests cover authority boundaries, string-registry removal, duplicate route rejection, route immutability, and upgrade continuity.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No owner-directed migration or silent replacement path exists.

## ABI / deploy / cutover impact

- ABI: removes AccessControl/admin-role functions and constants plus the string protocol registry/getters; adds typed owner/swapper, lending-route status, and add-only route functions. Exact selectors belong in the implementation PR after the migration gate is answered.
- Scripts: all deployment and add-on scripts must use the owner-governed API. No broadcast in this PR.
- Cutover: fresh relaunch deployment. Governance must use a new route index for every later handler version and **must never deregister an old route** — old entries are what let users exit the handler holding their funds.
- Cutover: cooperative migration is **not** shipped. The handlers deployed at this cutover will never gain a migration hook, so every route change is a user-performed withdraw and re-entry. This is not a permanent protocol commitment: a future handler generation may ship the source-side hook, enabling migration from that generation onwards.
- Cutover: register every route index with its class before assigning handlers to it. Index `0` is pre-registered as idle by the constructor; `IDLE_INDEX` in `script/Constants.sol` stays `0` for the relaunch map, but nothing may assume idle implies index `0`.
