# R52 — Allowlisted Dex path failover

Status: **not started** · Assigned: no · Optional/further-review: no

PR 51 of the relaunch stack; planned GitHub implementation PR **#104**. Stack on R51 / GitHub #103.
One chat/PR owns only this persistent path-governance change.

## Objective

Let the swapper recover a Dex handler from a drained, paused, or otherwise unusable active pool without
waiting for a multisig transaction, while governance remains the only authority that can approve the exact
encoded paths the handler may activate. The OperationsAdmin owner retains a direct break-glass activation
path among those same approved routes.

This is availability failover, not permission for arbitrary routing or per-batch best-route selection.

## Why this is separate from R51

R51 adds an ephemeral bound to one purchase call and touches the DcaManager/handler batch ABI. R52 changes
who may mutate persistent handler configuration, adds an OperationsAdmin policy registry, changes deploy
sequencing, and requires a route-health runbook. Keeping them separate makes the two trust-boundary changes
independently reviewable and keeps R51's wide mechanical tuple diff away from path authorization.

The oracle floor limits economic loss but does not make an encoded path non-security-sensitive. A path also
selects intermediate ERC20s and pools, affects callback/availability behavior, and persists after the caller
transaction. Governance must therefore approve exact complete paths, not components the bot can recombine.

## Settled decisions

**No open product decisions.** Implement these choices:

1. Reuse the existing OperationsAdmin swapper allowlist. BitChill has no separately operated routing key;
   another role would add storage, rotation, deploy, and monitoring work without least-privilege benefit in
   the actual operating model.
2. The `OperationsAdmin` owner is also authorized to activate an approved path directly. This is a genuine
   break-glass path, not a bypass: even governance cannot activate a path it has not first allowlisted.
   Requiring the Safe to temporarily add itself as a swapper adds incident steps without reducing power.
   This authority is specifically the OperationsAdmin owner; slippage, safety-floor, oracle, and fee setters
   remain controlled by the handler owner. The intended steady-state mainnet owner of both contracts is the
   same `MAINNET_OWNER` Safe. Full deployments temporarily leave both with the broadcaster until the Safe
   accepts their two-step transfers; add-on scripts use the current OperationsAdmin owner for the new handler.
   Deployment tests and runbooks must prove the eventual Safe is the same. If governance later transfers only
   one contract, the two authorities deliberately diverge rather than one owner silently inheriting the other.
3. Allowlist the exact canonical Uniswap V3 encoded path per handler. Governance supplies the full `bytes`
   to `setPurchasePathAllowed`; OperationsAdmin hashes it for storage. Full bytes in calldata/event make the
   approval auditable and avoid a hash-only runbook, while the mapping stays `handler => pathHash => bool`.
4. Reject revocation of the active path. Governance or the swapper must activate another allowed path first,
   then governance may revoke the old one. This preserves the invariant that every active path is allowed
   without adding an allowlist lookup to every protocol-paid purchase.
5. A revoked swapper cannot make further changes, but its last activated path persists. Incident recovery is
   therefore: revoke the key, restore the preferred approved path with the OperationsAdmin owner if needed,
   then revoke obsolete paths. Do not call swapper revocation alone a routing kill switch.
6. Deploy sequence is: construct Dex handler (constructor installs its initial path), read `getSwapPath()`,
   allowlist those exact bytes, then `assignTokenHandler`. An unassigned handler cannot receive schedule funds,
   so the initial allowlist can safely be seeded before assignment. Mainnet add-ons put allowlist + assignment
   in the Safe runbook/batch after the deployer creates the handler.
7. Resolve OperationsAdmin through the handler's pinned DcaManager when `setPurchasePath` is called. Do not
   add a separately supplied admin constructor address that could disagree with DcaManager. These are rare
   configuration calls, so the extra read is preferable to a new configuration seam; re-measure the exact
   implementation.
8. Keep path activation as its own transaction and persistent state. Do not add `pathIndex` to `Batch`, a
   caller-supplied path, or an atomic switch-and-buy entry point in this PR.
9. The swapper bot remains the only signer. Route discovery/quoting may consume a reusable module or read-only
   service derived from `rsk-uniswap-pools`; that process never receives the swapper private key.

## Authorization and registry shape

The intended surface is equivalent to:

```solidity
function setPurchasePathAllowed(address handler, bytes calldata encodedPath, bool allowed) external;
function isPurchasePathAllowed(address handler, bytes32 pathHash) external view returns (bool);
function requirePurchasePathSetter(address caller, bytes32 pathHash) external view;
```

- `setPurchasePathAllowed` is owner-only, rejects a non-contract handler, malformed/empty V3 path bytes,
  unchanged state, and revocation of `keccak256(IPurchaseUniswap(handler).getSwapPath())`. On both approval
  and revocation it must make the new admin→handler view call and validate that `getSwapPath()` succeeds and
  returns a canonical non-empty V3 path. A missing, reverting, or malformed getter reverts the named
  `OperationsAdmin__InvalidDexHandler(address handler)` error rather than leaking an opaque external-call or
  ABI-decode failure. The call is static/read-only; it validates the target surface and supplies the active
  path used by the revocation check.
- `requirePurchasePathSetter` is called by the handler. It keys the path permission by `msg.sender`, so one
  handler cannot assert against another handler's allowlist. It accepts `caller` only when it is an active
  swapper or the OperationsAdmin owner, and then requires the hash to be allowed for the calling handler.
- The permission event includes `address indexed handler`; `pathHash`, `encodedPath`, and `allowed` remain
  data under R9's indexing rule.

Exact names/error arguments may be shortened only if the final handler-size measurement requires it; preserve
the semantics and diagnostic values. OperationsAdmin has ample bytecode margin, so do not trade away auditability
there to save bytes on the wrong contract.

## Handler behavior

`PurchaseUniswap.setPurchasePath` builds the canonical path first using the same pinned purchase token and
WRBTC endpoints as today. It then resolves OperationsAdmin from `i_dcaManager`, calls the combined assertion
with `msg.sender` and `keccak256(newPath)`, and only then writes/emits the new path. The constructor continues
to use an internal installation path and makes no external authorization call.

The current `PurchaseUniswap_NewPathSet` natspec must stop saying “Owner.” It reports an approved path activated
by a swapper or the registry owner. Slippage percent, safety floor, and oracle setters remain handler-owner-only.

## Size constraint

The R51 implementer records the new baseline. Measure R52 from that exact commit under `[profile.default]`.
An earlier combined prototype showed that storing the allowlist on `PurchaseUniswap` can exceed EIP-170 on
`LayerBankErc20HandlerDex`; do not retry that architecture. Policy storage, errors, and validation belong on
`OperationsAdmin`, which currently has more than 18k of margin. Keep only path building plus one combined
authorization call on the handler.

## Scope

- [ ] Add the per-handler exact-path allowlist, owner setter, getter, combined assertion view, transition event,
  and diagnostic errors to `IOperationsAdmin` / `OperationsAdmin`.
- [ ] The owner setter accepts full encoded path bytes, stores their hash, and rejects no-op writes. Validate the
  generic V3 path shape (`20 + n * 23`, at least one pool); the handler remains responsible for pinned endpoints.
  Validate the handler's Dex getter on every write and normalize any failed/malformed call to
  `OperationsAdmin__InvalidDexHandler(handler)`.
- [ ] Active-path revocation queries `getSwapPath`, hashes it, and reverts. A non-active allowed path can be revoked.
- [ ] Change `IPurchaseUniswap` natspec and `PurchaseUniswap.setPurchasePath` authorization as described above.
  Constructor path installation stays internal and authorization-free.
- [ ] `DeployDexSwaps` and `DeployUsdrifHandler` seed the constructor-installed path before handler assignment.
  `DeployLayerBankHandler` is MoC-only and must **not** be changed for this Dex feature.
- [ ] Update live/add-on Safe runbooks printed by scripts: read current path, allow it, assign the handler, and then
  perform token-specific DcaManager setup such as the USDT0 minimum.
- [ ] Assert the production ownership topology: after acceptance, OperationsAdmin and every Dex handler name the
  same Safe; document the broadcaster/pending-owner transition and the independent behavior if owners later diverge.
- [ ] Re-measure every Dex leaf and OperationsAdmin, and record configuration gas for allow/activate/revoke.

## Off-chain relaunch gate

In the same turn as the contracts PR, update the matching swapper-bot issue and open/update a cross-linked
`rsk-uniswap-pools` issue if that repo supplies route intelligence. The issues must settle and test:

- one signing boundary: only swapper-bot holds the key;
- a versioned production list of governance-approved encoded paths and hashes per handler;
- route discovery/quotes for DOC, USDRIF, and USDT0 using raw integer amounts;
- pool health and quote thresholds that trigger failover, plus hysteresis/cooldown so the bot does not oscillate;
- normal failover is fully automatic among paths the Safe approved ahead of time; it does not wait for a Safe
  transaction or ask governance to adjust the R51 oracle floor for routine weekly conditions;
- for every enabled Dex handler advertised as having automatic path failover, at least one alternate exact path
  is Safe-approved and validated at supported operating sizes against the same re-locked R51 oracle floor before
  relaunch; switching paths must not require a slippage-setting change. If no viable alternate exists, the cutover
  record must label that handler **single-path / no automated path failover**; it may still use bounded re-quote
  and split retries, but exhaustion pages governance instead of pretending the allowlist adds redundancy;
- transaction order: activate approved path, wait for confirmation, re-read `getSwapPath`, obtain a fresh quote for
  that path, then compose the R51 minimum and purchase;
- behavior when another authorized operator changes the path between quote and broadcast (re-quote/re-estimate,
  never silently use a quote for a different path);
- bounded retry/split/path attempts before alerting; governance is paged only when every approved path remains
  structurally unusable or the signing key is suspected compromised;
- alerts and the owner runbook for compromised-key recovery and active-path restoration;
- no auto-allowlisting: discovery proposes routes for governance review, but only the Safe calls the allowlist setter.

The contracts PR can merge before this work, but Dex relaunch is blocked until the route list, bot policy, and
incident runbook pass their own tests. Alternate-path availability is therefore a relaunch-readiness result,
not a PR 104 merge condition.

## Out of scope

- [ ] `minRbtcOut` or either DcaManager purchase ABI (R51).
- [ ] Arbitrary/component allowlists, bot-composed intermediate combinations, or on-chain route discovery.
- [ ] Per-batch path selection, size-dependent routing, `pathIndex`, free-form `bytes`, or switch-and-buy.
- [ ] Swapper-writable slippage percent, safety floor, oracle, router, WRBTC, or stablecoin.
- [ ] Automatic revocation/allowlisting from pool health, partial across-handler success, or a second signing service.
- [ ] Changing `_getAmountOutMinimum`, deploy slippage defaults, or purchase-path reentrancy policy.

## Files likely touched

- `src/interfaces/IOperationsAdmin.sol`, `src/OperationsAdmin.sol`
- `src/interfaces/IPurchaseUniswap.sol`, `src/PurchaseUniswap.sol`
- `script/DeployDexSwaps.s.sol`, `script/DeployUsdrifHandler.s.sol`
- `test/unit/OperationsAdminTest.t.sol`, `test/unit/PurchaseUniswapSettingsTest.sol`
- `test/unit/deployment/LiveDeployPathTest.t.sol`, `NewHandlerDeploymentTest.t.sol`, and
  `Usdt0DexDeploymentTest.t.sol`
- Dex handler suites that currently assert owner-only path setting

## Required tests

- Allowlisted paths can be activated by a swapper and the OperationsAdmin owner; arbitrary EOAs cannot.
- Nobody, including the owner, can activate a non-allowlisted path.
- Handler A cannot use handler B's path permission.
- The setter rejects non-contract handlers, malformed encoded paths, and unchanged permission writes.
- The setter rejects a contract with no `getSwapPath`, a getter that reverts, and malformed getter return data
  with `OperationsAdmin__InvalidDexHandler(handler)` on both allow and revoke operations.
- A non-active path can be revoked and cannot later be activated.
- The active path cannot be revoked. After switching to another allowed path, the former path can be revoked.
- Revoking a swapper stops future path changes but does not mutate the active path; owner recovery works.
- Constructor installation still works without authorization.
- Both live Dex deployment scripts allowlist the exact `getSwapPath()` bytes before assignment; mainnet non-owner
  add-ons print the complete Safe runbook instead of claiming they configured it.
- Mainnet deployment tests prove OperationsAdmin and handlers converge on the same Safe after ownership acceptance.
  A focused divergent-owner test proves the OperationsAdmin owner can activate an allowed path but cannot call
  handler-owner slippage/oracle setters, while the handler owner has the inverse authority unless also allowlisted
  as a swapper.
- Slippage/oracle setters remain owner-only and purchases still use the active path plus both R43/R51 bounds.

Then run the full `AGENTS.md` done-gate and both required forks. A fork test should allow and activate a second
real path only if its pools exist and have liquidity; otherwise prove the deployed initial path is allowlisted and
that an unauthorized/hash-mismatched activation fails.

## Success criteria

- [ ] Every active Dex path is governance-allowlisted, including the constructor path before assignment.
- [ ] The swapper and OperationsAdmin owner can switch only among exact approved paths.
- [ ] Active permission cannot be revoked until another approved path is active.
- [ ] A compromised swapper cannot widen slippage or introduce an unapproved token/pool combination.
- [ ] All Dex handlers remain below EIP-170 in the default deploy profile.
- [ ] Deployment scripts and off-chain issues contain complete normal/failover/recovery sequencing.
- [ ] Steady-state ownership is the same production Safe, transitional ownership is documented/tested, and path
  versus handler-configuration authority remains explicit if ownership later diverges.
- [ ] R9 indexing and R10 natspec rules cover all new/repurposed surfaces.
- [ ] No open product decisions.

## ABI / deploy / cutover impact

- **ABI:** DcaManager and `IPurchaseRbtc` are unchanged. OperationsAdmin gains the path-policy setter/getter/assertion,
  event, and errors. `setPurchasePath` keeps its selector but changes authorization semantics.
- **Deploy:** Dex handlers must have their constructor path allowlisted before assignment. Update only actual Dex deploy
  paths (`DeployDexSwaps`, `DeployUsdrifHandler`) and their Safe runbooks/tests.
- **Consumers:** update `swapper-bot#6` (or the matching issue) with routing policy and recovery. Update
  `bitchill-monitoring#10` for the new event/errors and changed `NewPathSet` actor semantics. Update `front-end#22`
  for ABI regeneration if its hardcoded handler/admin ABIs include these contracts. No data-api or metrics-dashboard
  issue is required unless their inspected code consumes path state or route labels.
