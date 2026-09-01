# R52 — Allowlisted Dex path failover

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 51 of the relaunch stack; GitHub implementation PR **#104**. Stack on R51 / GitHub #103.
This PR also turns on the default-profile optimizer (`optimizer = true`, `optimizer_runs = 200`,
`via_ir = false`) so handler-local path policy stays under EIP-170. The Rootstock testnet +
Blockscout re-proof of that pin is **in this PR** (`script/DeployOptimizerProof.s.sol`) and is an
open merge blocker: **#104 is not merge-ready** until that CREATE verifies on Blockscout.
R53's optimizer-baseline work is absorbed here. Schedule top-up is R54; solx / via-IR evaluation
and `ZeroTokenPurchaseUniswap` repair are R55. Those remaining items are defined in stacked
[#105](https://github.com/BitChillRSK/dca-contracts/pull/105), which will need rebasing after this
PR because its original R53 optimizer plan is superseded. There is no `[profile.deploy]`.

One chat/PR owns only this persistent path-governance change.

## Objective

Let the swapper recover a Dex handler from a drained, paused, or otherwise unusable active pool without
waiting for a multisig transaction, while the **handler owner** remains the only authority that can approve
the exact encoded paths the handler may activate. An active OperationsAdmin swapper, or the handler owner,
may switch among those approved paths.

This is availability failover, not permission for arbitrary routing or per-batch best-route selection.

## Why this is separate from R51

R51 adds an ephemeral bound to one purchase call and touches the DcaManager/handler batch ABI. R52 changes
who may mutate persistent handler configuration, adds a per-handler path allowlist, changes deploy
sequencing, and requires a route-health runbook. Keeping them separate makes the two trust-boundary changes
independently reviewable and keeps R51's wide mechanical tuple diff away from path authorization.

The oracle floor limits economic loss but does not make an encoded path non-security-sensitive. A path also
selects intermediate ERC20s and pools, affects callback/availability behavior, and persists after the caller
transaction. Governance must therefore approve exact complete paths, not components the bot can recombine.

## Settled decisions

**No open product decisions.** Implement these choices:

1. Reuse the existing OperationsAdmin swapper allowlist for **activation** only. BitChill has no separately
   operated routing key. OperationsAdmin continues to own that global list and nothing about purchase paths.
2. Path **approval and revocation** are handler-owner-only. Path **activation** is the handler owner **or** an
   active OperationsAdmin swapper. Production expects the same Safe to own OperationsAdmin and every handler.
   If those owners later diverge, authority diverges with them: the OperationsAdmin owner cannot activate or
   allowlist paths on a handler they do not own, and there is no extra break-glass for that case.
3. Allowlist the exact canonical Uniswap V3 encoded path. The owner setter takes `intermediateTokens` and
   `poolFeeRates` and derives bytes through the same `_encodePurchasePath` used by `setPurchasePath`. The event
   includes the derived path and `keccak256` hash for auditing. Do not index the hash, bytes, or arrays (R9).
4. Reject revocation of the active path. Activate another allowed path first, then revoke the old one. This
   preserves the invariant that every active path is allowed without adding an allowlist lookup to purchases.
5. A revoked swapper cannot make further changes, but its last activated path persists. Incident recovery
   order is **mandatory**: `revokeSwapper` first, then restore the preferred approved path (handler owner or a
   remaining swapper), then revoke obsolete paths. A still-authorized swapper can front-run each
   `setPurchasePathAllowed(..., false)` by re-activating that path.
6. Deploy sequence: construct Dex handler (constructor encodes once, writes `s_swapPath`, marks that
   hash allowed, and emits `PurchaseUniswap_NewPathSet` plus `PurchaseUniswap_PurchasePathAllowedSet`),
   then `assignTokenHandler`. Every active path is allowed on-chain; there is no assigned-without-allowlisting
   window. New paths after construction are owner-approved through `setPurchasePathAllowed`.
7. Resolve OperationsAdmin only to call `isSwapper(msg.sender)` when the caller is not the handler owner.
   Do not add a separately supplied admin constructor address. Keep `setPurchasePath` check order:
   encode, then allowlist revert, then owner/swapper revert. The allowlist is public; this order avoids
   an unnecessary admin lookup. Changing it would only affect cosmetic error precedence.
8. Keep path activation as its own transaction and persistent state. Do not add `pathIndex` to `Batch`, a
   caller-supplied path, or an atomic switch-and-buy entry point in this PR.
9. The swapper bot remains the only signer. Route discovery/quoting may consume a reusable module or read-only
   service derived from `rsk-uniswap-pools`; that process never receives the swapper private key.
10. Do not introduce another abstract contract. `PurchaseUniswap` is the boundary; there is no second consumer.

## Authorization and registry shape

Policy storage lives entirely on `PurchaseUniswap`. The intended surface is:

```solidity
function setPurchasePathAllowed(
    address[] memory intermediateTokens,
    uint24[] memory poolFeeRates,
    bool allowed
) external; // onlyOwner

function isPurchasePathAllowed(bytes32 pathHash) external view returns (bool);

function setPurchasePath(address[] memory intermediateTokens, uint24[] memory poolFeeRates) external;
```

- `setPurchasePathAllowed` encodes through pinned stablecoin and WRBTC, rejects unchanged permission, and
  rejects revocation of `keccak256(s_swapPath)`. Wrong hop/fee lengths revert
  `PurchaseUniswap__WrongNumberOfTokensOrFeeRates` via `_encodePurchasePath`.
- `setPurchasePath` encodes first, requires the hash to be allowlisted, then requires `msg.sender == owner()`
  or `IOperationsAdmin(dcaManager.getOperationsAdminAddress()).isSwapper(msg.sender)`.
- Constructor `_setPurchasePath` is constructor-only: encode once, write `s_swapPath`, mark
  `s_purchasePathAllowed[keccak256(path)] = true`, emit both path events.
- Public `setPurchasePath` does not call `_setPurchasePath`.
- Purchases read `s_swapPath` only. No allowlist SLOAD on the purchase path.
- `OperationsAdmin` has no purchase-path mapping, setter, getter, assertion, event, errors, handler-policy
  calls, or returndata decoder.

## Handler behavior

`PurchaseUniswap_NewPathSet` natspec reports an approved path activated by construction, a swapper, or this handler's owner.
Slippage percent, safety floor, and oracle setters remain handler-owner-only.

## Size constraint

Measure under `[profile.default]` with the optimizer on and `via_ir = false`. An earlier unoptimized
prototype exceeded EIP-170 when policy lived on the Dex leaf; that is not a reason to keep a centralized
admin registry. Full `forge build --sizes` (not `--match-*`) is the record.

## Scope

- [x] Add the per-handler exact-path allowlist, owner setter, getter, transition event, and diagnostic errors
  to `IPurchaseUniswap` / `PurchaseUniswap`.
- [x] The owner setter accepts path components, stores the derived hash, emits path+hash, and rejects no-op
  writes and active-path revocation.
- [x] Constructor path installation stays internal, self-allowlists the initial path, and emits both
  `PurchaseUniswap_NewPathSet` and `PurchaseUniswap_PurchasePathAllowedSet`.
- [x] Remove every purchase-path API from `IOperationsAdmin` / `OperationsAdmin`.
- [x] `DeployDexSwaps` and `DeployUsdrifHandler` do **not** call `setPurchasePathAllowed` for the
  constructor path. `DeployLayerBankHandler` is MoC-only and must **not** be changed for this Dex feature.
- [x] Update live/add-on Safe runbooks: before `assignTokenHandler`, read `handler.getSwapPath()` and
  confirm it matches the intended stablecoin / intermediate pools / WRBTC route; constructor already
  approved that path. Then token-specific DcaManager setup such as the USDT0 minimum.
- [x] Enable default-profile optimizer (`optimizer = true`, `optimizer_runs = 200`, `via_ir = false`).
      Remove vestigial `[profile.deploy]`. Own the Rootstock re-proof of optimizer-on (not via-IR) in this PR
      (`script/DeployOptimizerProof.s.sol`); the unchecked Blockscout tick below is the merge blocker.
- [x] Re-measure every Dex leaf and OperationsAdmin, and record configuration gas for allow/activate/revoke.

## Off-chain relaunch gate

In the same turn as the contracts PR, update the matching swapper-bot issue and the cross-linked
`rsk-uniswap-pools` issue if that repo supplies route intelligence. The issues must settle and test:

- one signing boundary: only swapper-bot holds the key;
- a versioned production list of governance-approved encoded paths and hashes per handler;
- route discovery/quotes for USDRIF and USDT0 using raw integer amounts (DOC is not a shipped Dex route);
- pool health and quote thresholds that trigger failover, plus hysteresis/cooldown so the bot does not oscillate;
- normal failover is fully automatic among paths the handler owner approved ahead of time;
- for every enabled Dex handler advertised as having automatic path failover, at least one alternate exact path
  is approved and validated at supported operating sizes against the same re-locked R51 oracle floor before
  relaunch; switching paths must not require a slippage-setting change. If no viable alternate exists, the cutover
  record must label that handler **single-path / no automated path failover**;
- transaction order: activate approved path, wait for confirmation, re-read `getSwapPath`, obtain a fresh quote for
  that path, then compose the R51 minimum and purchase;
- behavior when another authorized operator changes the path between quote and broadcast (re-quote/re-estimate,
  never silently use a quote for a different path);
- bounded retry/split/path attempts before alerting;
- alerts and the owner runbook for compromised-key recovery and active-path restoration;
- no auto-allowlisting: discovery proposes routes for governance review, but only the handler owner calls the
  allowlist setter.

The contracts PR can merge before this work, but Dex relaunch is blocked until the route list, bot policy, and
incident runbook pass their own tests.

## Out of scope

- [ ] `minRbtcOut` or either DcaManager purchase ABI (R51).
- [ ] Arbitrary/component allowlists, bot-composed intermediate combinations, or on-chain route discovery.
- [ ] Per-batch path selection, size-dependent routing, `pathIndex`, free-form `bytes`, or switch-and-buy.
- [ ] Swapper-writable slippage percent, safety floor, oracle, router, WRBTC, or stablecoin.
- [ ] Automatic revocation/allowlisting from pool health, partial across-handler success, or a second signing service.
- [ ] Changing `_getAmountOutMinimum`, deploy slippage defaults, or purchase-path reentrancy policy.
- [ ] OperationsAdmin-owner break-glass activation when handler ownership has diverged.
- [ ] A new abstract policy contract.
- [ ] Rootstock testnet / Blockscout re-proof of via-IR (R55 in [#105](https://github.com/BitChillRSK/dca-contracts/pull/105)).
- [ ] Schedule top-up (R54) and solx evaluation (R55) in [#105](https://github.com/BitChillRSK/dca-contracts/pull/105).

## Files likely touched

- `src/interfaces/IPurchaseUniswap.sol`, `src/PurchaseUniswap.sol`
- `foundry.toml` (default optimizer on; no `[profile.deploy]`)
- `script/DeployDexSwaps.s.sol`, `script/DeployUsdrifHandler.s.sol`, `script/DeployOptimizerProof.s.sol`
- `README.md` (mainnet add-on Safe runbook + compromised-swapper order)
- `Makefile` (`fork-dex-path`)
- `test/unit/PurchaseUniswapSettingsTest.sol`, `test/unit/DexPathFailoverTest.t.sol`
- `test/unit/deployment/LiveDeployPathTest.t.sol`, `NewHandlerDeploymentTest.t.sol`, and
  `Usdt0DexDeploymentTest.t.sol`
- Dex handler suites that currently assert path setting

## Required tests

- Allowlisted paths can be activated by a swapper and the handler owner; arbitrary EOAs cannot.
- The OperationsAdmin owner cannot activate or allowlist when they do not own the handler.
- Nobody can activate a non-allowlisted path.
- Isolation is per-handler storage (no shared admin mapping): `testAllowlistIsLocalToEachHandler`.
- The setter rejects unchanged permission writes and wrong hop/fee lengths on **`setPurchasePathAllowed`**
  (`testSetPurchasePathAllowedRevertsWithWrongArrayLengths`; encode is shared with `setPurchasePath`).
- A non-active path can be revoked and cannot later be activated.
- The active path cannot be revoked. After switching to another allowed path, the former path can be revoked.
- Revoking a swapper stops future path changes but does not mutate the active path; handler-owner recovery works.
- Constructor self-allowlists the active path: a freshly constructed handler reports
  `isPurchasePathAllowed(keccak256(getSwapPath()))` without calling the external setter
  (`testConstructorSelfAllowlistsActivePathWithoutSetter`).
- Both live Dex deployment scripts assign without a constructor-path `setPurchasePathAllowed`;
  mainnet non-owner add-ons print the complete Safe runbook (including the `getSwapPath()` checkpoint)
  instead of claiming they assigned the handler.
- Slippage/oracle setters remain owner-only and purchases still use the active path plus both R43/R51 bounds.

Then run the full `AGENTS.md` done-gate and both required forks (`make fork-sovryn`, `make fork-tropykus`). Those
lanes default to `SWAP_TYPE=mocSwaps` and skip this suite (`vm.skip` in `setUp`). Dex path evidence on a fork is
`make fork-dex-path` (LayerBank / USDRIF / dexSwaps, `DexPathFailoverTest` only).

## Success criteria

- [x] Every active Dex path is allowlisted on-chain, including the constructor path at construction.
- [x] The swapper and handler owner can switch only among exact approved paths.
- [x] Active permission cannot be revoked until another approved path is active.
- [x] A compromised swapper cannot widen slippage or introduce an unapproved token/pool combination.
- [x] All Dex handlers remain below EIP-170 in the default (optimized, no-IR) deploy profile.
- [x] Deployment scripts and off-chain issues contain complete normal/failover/recovery sequencing.
- [x] R9 indexing and R10 natspec rules cover all new/repurposed surfaces.
- [x] No open product decisions.
- [ ] Rootstock testnet CREATE of optimizer-on `OperationsAdmin` verified on Blockscout. **This PR
      is not merge-ready until that CREATE succeeds and verifies.** Command
      (as `TESTNET_OWNER`, chain 31; this repo does not `--broadcast` from the implementer):

```bash
# On feat/r52-allowlisted-dex-path-failover, with .env sourced (`LENDING_PROTOCOL` must be set;
# DeployBase reads it in the constructor). `--account` alone leaves `run()`'s `msg.sender` as
# Foundry's default sender (`0x1804c8…`), which is not `TESTNET_OWNER`. Pass `--sender` and the
# keystore whose address is `0x31e0FacEa072EE621f22971DF5bAE3a1317E41A4` (check with
# `cast wallet address --account <name>`). Forge requires `path:ContractName` for `*.s.sol`.
REAL_DEPLOYMENT=true forge script script/DeployOptimizerProof.s.sol:DeployOptimizerProof \
  --rpc-url $RSK_TESTNET_RPC_URL \
  --account <keystore_that_is_TESTNET_OWNER> \
  --sender 0x31e0FacEa072EE621f22971DF5bAE3a1317E41A4 \
  --broadcast --legacy \
  --verify --verifier blockscout --verifier-url $BLOCKSCOUT_API_URL
```

Record the CREATE tx and Blockscout match in this spec and the PR body, then tick this box.

GitHub [#104](https://github.com/BitChillRSK/dca-contracts/pull/104). Default-profile runtime
(`optimizer = true`, `optimizer_runs = 200`, `via_ir = false`; EIP-170 24,576): `OperationsAdmin`
3,227 (margin 21,349); `LayerBankErc20HandlerDex` 15,565 (9,011); `SovrynErc20HandlerDex` 15,352
(9,224); `TropykusErc20HandlerDex` 15,496 (9,080); `DcaManager` 13,767 (10,809). Config gas on Anvil
USDRIF dex-layerbank: allow ~41k, activate ~35k, revoke ~16k.

## ABI / deploy / cutover impact

- **ABI:** DcaManager and `IPurchaseRbtc` are unchanged. `IPurchaseUniswap` gains the path-policy setter/getter,
  event, and errors. `setPurchasePath` keeps its selector but changes authorization. OperationsAdmin **loses**
  any purchase-path APIs (none remain on R51 + this redesign).
- **Deploy:** Dex constructor self-allowlists the initial path. Before `assignTokenHandler`, the Safe
  reads `getSwapPath()` and confirms the intended route. Update only actual Dex deploy paths
  (`DeployDexSwaps`, `DeployUsdrifHandler`) and their Safe runbooks/tests.
- **Consumers:** update `swapper-bot#6` with routing policy and recovery. Update `bitchill-monitoring#10` for
  the new handler event/errors and changed `NewPathSet` actor semantics. Update `front-end#22` for ABI
  regeneration if its hardcoded handler ABIs include these contracts. No data-api or metrics-dashboard issue
  is required unless their inspected code consumes path state or route labels.
