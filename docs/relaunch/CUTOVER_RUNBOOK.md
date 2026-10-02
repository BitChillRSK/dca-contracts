# Cutover runbook — relaunch (R73)

Human operator only. Agents must not `--broadcast`.

## Preconditions

1. Merge the full relaunch stack in order, freeze a release commit/tag, and make that exact revision
   the audit and deployment target.
2. Complete the independent security review against that revision; resolve or explicitly accept every
   finding before broadcast.
3. Approve the launch economic matrix and make `script/Constants.sol` match it: fee settings on every
   handler, per-token minimum purchase amounts, and the minimum purchase period. The current values
   are tabulated under **Launch configuration** in [`AUDIT_GUIDE.md`](../../AUDIT_GUIDE.md).
4. Deploy and Blockscout-verify a representative `FOUNDRY_PROFILE=deploy` (`via_ir = true`) artifact
   on Rootstock testnet. This is the outstanding R60 compiler/verifier proof. On that deployment,
   execute at least two guarded `DcaManager` user calls in separate transactions (for example
   `createDcaSchedule`, then `updatePurchaseAmount` on the new schedule). The reentrancy guard is the
   first `TSTORE` in shipped bytecode ([R82](./R82-transient-reentrancy-guard.md)); the second call
   succeeding proves rskj executes it and clears the lock between transactions.
5. Green on the frozen revision:
   - `make check`
   - `make check-deploy`
   - `make fork-sovryn`
   - `make fork-layerbank`
   - `make fork-dex-path` (Dex path allowlist)
6. Static analysis triaged in [`R73-RELEASE_RECORD.md`](./R73-RELEASE_RECORD.md).
7. `RSK_MAINNET_RPC_URL`, Blockscout verifier URL, deployer keystore/Ledger ready.
8. `INITIAL_SWAPPER` = production bot EOA (non-zero).
9. Safe (`MAINNET_OWNER`) and fee collector (`MAINNET_FEE_COLLECTOR`) match `script/Constants.sol`.
   The collector is a passive EOA. Each purchase **credits** its accumulated rBTC on that
   handler; it withdraws through `DcaManager.withdrawAccumulatedRbtc` per token × route (Dex
   unwraps WRBTC then pays native). A wallet that cannot receive native rBTC does not revert
   purchases; it cannot claim until it can receive, and `setFeeCollector` does not migrate
   already-credited balances. Sweep every live handler after deploy.

## Deploy

```bash
REAL_DEPLOYMENT=true \
INITIAL_SWAPPER=<bot-eoa> \
FOUNDRY_PROFILE=deploy \
forge script script/DeployFinal.s.sol:DeployFinal \
  --rpc-url $RSK_MAINNET_RPC_URL \
  --account <deployer-eoa> \
  --broadcast --legacy \
  --verify --verifier blockscout --verifier-url $BLOCKSCOUT_API_URL
```

`DeployFinal.run()` is **mainnet-only** (fail-closed incomplete map on testnet). For a
`via_ir` Rootstock **testnet** bytecode proof, use a representative component script under
`FOUNDRY_PROFILE=deploy` (see R60); that is not a substitute for this full-stack mainnet cutover.

## Ownership handoff

Foundry always broadcasts from an EOA (`--account` / `--ledger`). A Safe cannot sign that transaction.
Owner and fee-collector addresses live in `script/Constants.sol`:

| Network | Owner | Fee collector |
|---|---|---|
| Testnet | `TESTNET_OWNER` (the funded EOA that broadcasts) | same EOA |
| Mainnet | `MAINNET_OWNER` (the BitChill Safe) | `MAINNET_FEE_COLLECTOR` |

**Mainnet.** Broadcast from an EOA, not the Safe. The script constructs `OperationsAdmin`,
`DcaManager`, and every handler with the EOA as owner, so `registerRoute` and `assignHandler` succeed
in the same broadcast, and then calls `transferOwnership(MAINNET_OWNER)` on each. That only proposes.
The Safe sends `acceptOwnership()` to each contract. Until those accepts land, the deploying EOA can
still govern and can propose a different address if the Safe address was wrong.

**Testnet.** Broadcast from `TESTNET_OWNER`. The lane scripts revert before any `CREATE` if a
different key is used. That EOA owns every contract when the script ends and `pendingOwner` is zero,
so there is no `acceptOwnership`.

Later ownership changes (a new Safe, a recovered wallet) are the same two steps: the current owner
calls `transferOwnership(new)` and the incoming owner calls `acceptOwnership()`. `renounceOwnership`
always reverts.

## After broadcast

1. Copy every address from the script log into the consumer issue / ops sheet.
2. From the Safe, `acceptOwnership()` on `OperationsAdmin`, `DcaManager`, and all seven handlers.
3. Confirm Dex `getSwapPath()` on each Dex handler matches the intended route (constructor
   already allowlisted it).
4. Confirm `isSwapper(INITIAL_SWAPPER)` and per-token mins (DOC/USDRIF `25 ether`, USDT0 `25e6`).
5. Publish addresses to `front-end`, `swapper-bot`, `data-api`, `bitchill-monitoring`,
   `metrics-dashboard`, and add them to [`ADDRESSES.md`](../../ADDRESSES.md).
6. Enable bot ticks only after a successful dry-run simulation against the new stack.

## Abort / rollback

Immutable contracts: do not “patch.” Abort before Safe accept if verification or wiring is wrong
(deployer EOA still owns until accept). After accept, recovery is new route indexes + user
exit/re-entry (R13), never same-index overwrite or owner rescue.

## Adding a handler after cutover

Handler assignment is add-only, and `DeployFinal` assigns every pair the existing add-on scripts
target (`DeployIdleHandler`, `DeployLayerBankHandler`, `DeployUsdrifHandler`). Those scripts remain
for stacks built by the lane scripts. A handler for a new token or a new route index follows the same
shape and order.

The add-on scripts revert while `pendingOwner` is set on `OperationsAdmin` or `DcaManager`, so run
them only after the Safe has accepted. On mainnet the Safe owns `OperationsAdmin`, so the Foundry EOA
deploys the handler and returns without assigning it. A Dex handler's constructor allowlists its
initial path. The handler stays unreachable until the Safe, in this order:

1. Calls `operationsAdmin.registerRoute(index, lends)` only if `getRouteClass(index)` is still
   `Unregistered`. A second registration reverts `RouteAlreadyRegistered`.
2. For a Dex handler, reads `handler.getSwapPath()` and verifies it matches the intended stablecoin,
   intermediate pools, and WRBTC. This is the human checkpoint before assignment.
3. Calls `dcaManager.setTokenMinPurchaseAmount(token, min)` in the token's own decimals if the token
   has no minimum yet (`25 ether` for an 18-decimal token, `25e6` for a 6-decimal one). There is no
   protocol-wide default, and `createDcaSchedule` reverts `TokenMinPurchaseAmountNotSet` without it.
4. Calls `operationsAdmin.assignHandler(token, index, handler)` last, so the token is never routable
   while creation still reverts.

## Compromised swapper

Revoke the swapper key **before** revoking any path. A still-allowlisted compromised key can
front-run each `setPurchasePathAllowed(..., false)` by re-activating that path. The order is:

1. `operationsAdmin.revokeSwapper(key)`.
2. If the active path on a Dex handler is not the preferred one, the handler owner or a remaining
   swapper calls `setPurchasePath` with the preferred allowlisted path.
3. The handler owner revokes obsolete paths with `setPurchasePathAllowed(..., false)`.

Revoking the swapper does not by itself change which path a handler uses. The worst case while the
key is live is stated under **Authority and trust boundaries** in
[`AUDIT_GUIDE.md`](../../AUDIT_GUIDE.md).

## Fee collector rotation

`setFeeCollector` redirects future fee credits only. rBTC already credited stays with the previous
collector address on each handler, and only that address can withdraw it. Before rotating, have the
current collector call `DcaManager.withdrawAccumulatedRbtc` for every live token × route, then call
`setFeeCollector` on every handler. If the rotation answers a lost or compromised collector key, the
balance already credited to it cannot be redirected; rotate at once to stop further credits.

## Ops history note

Standing `redeemDocRequest` queue entries on **pre-relaunch** MoC handlers: checked and closed
2026-09-07 (no stranded DOC / no unexpected settlement observed across ~2 years of that call
pattern). Relaunch handlers do not call `redeemDocRequest`.
