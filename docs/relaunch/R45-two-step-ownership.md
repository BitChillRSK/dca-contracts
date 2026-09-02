# R45 — Two-step ownership and safe initial ownership

Status: **PR [#82](https://github.com/BitChillRSK/dca-contracts/pull/82)** · Assigned: yes · Optional/further-review: no

PR 32 of the relaunch stack. Stack on R44 (PR 31). Must precede authority hardening and the ABI freeze.

## Objective

Use an acceptance-based ownership transfer on every first-party governance-owned contract, set the intended owner directly at construction, and make accidental renunciation impossible.

## Background

Single-step `transferOwnership` can permanently hand control to a typo, an address that cannot call back, or the wrong Safe. `OperationsAdmin` already forbids renunciation because freezing its add-only registry is unrecoverable; the same policy should apply consistently to `DcaManager` and handlers that own fee/oracle configuration.

OpenZeppelin v5 is already present from R44. A small shared governance base is preferable to three subtly different ownership policies. R39 supplies the handler bytecode headroom this must re-measure.

## Open product decisions

**Deploy vs final owner (follow-up on #82):** Foundry broadcasts from an EOA. Live contracts are constructed with that EOA as owner so `registerRoute` / `assignTokenHandler` can run in the same script. Testnet's EOA (`TESTNET_OWNER`) is the intended owner (no handoff). Mainnet proposes `MAINNET_OWNER` (the Safe) at the end of the script; the Safe must `acceptOwnership` on each contract. Direct-to-Safe construction is not used — a Safe cannot sign `forge script`.

## Scope

- [x] Add one shared first-party governance base over OZ `Ownable2Step`; its constructor takes a nonzero `initialOwner`, and `renounceOwnership` always reverts with one canonical custom error.
- [x] Migrate `DcaManager`, `OperationsAdmin`, and the handler ownership chain (`FeeHandler` / `TokenHandler` and concrete leaves) to that base without duplicate Ownable inheritance.
- [x] Thread `initialOwner` through production constructors and deploy helpers. Deployments finish owned by that address immediately; they must not rely on a later broadcaster-owned `transferOwnership`.
- [x] Test pending-owner, acceptance, wrong-caller rejection, replacement of a pending owner, zero owner rejection, and renounce rejection on manager, admin, and at least one concrete handler.
- [x] Update deployment tests to assert both final owner and zero pending owner.
- [x] Record selector/runtime/storage impact for every concrete handler.

## Out of scope

- [ ] Removing or changing `DcaManager.setOperationsAdmin` (R46).
- [ ] Timelocks, role hierarchies, multisig implementation, proxies, or delayed ownership transfers.
- [ ] Broadcasting an acceptance transaction.

## Files likely touched

- New shared governance base under `src/`
- `src/DcaManager.sol`, `src/OperationsAdmin.sol`, `src/FeeHandler.sol`, `src/TokenHandler.sol`
- Concrete handler constructors under `src/idle/`, `src/layerbank/`, `src/sovryn/`, and `src/tropykus-legacy/`
- Deployment helpers and ownership/deployment tests

## Required tests

Run targeted ownership and deployment suites, every handler lane needed by constructor compiler errors, `forge build --sizes`, then `make check`, `make ci`, and both fork lanes.

## Success criteria

- [x] No production first-party contract uses single-step `Ownable` directly.
- [x] Initial ownership is the Foundry broadcaster so live `onlyOwner` setup cannot orphan CREATEs; testnet that *is* the final owner, mainnet proposes the Safe.
- [x] Renunciation is impossible across manager, admin, and handlers.
- [x] Every concrete contract remains below EIP-170.
- [x] No open product decisions.

## Measured results

`BitChillOwnable` wraps OZ `Ownable2Step`, rejects `address(0)` via OZ `OwnableInvalidOwner`, and reverts `renounceOwnership` with `BitChillOwnable__OwnershipCannotBeRenounced`. Live scripts construct with the Foundry broadcaster as owner, then propose `MAINNET_OWNER` when that address differs. Testnet (`TESTNET_OWNER`) needs no accept. Governance and fee-collector addresses live in `script/Constants.sol`.

Dex constructors used to call `onlyOwner setPurchasePath` while `Ownable(msg.sender)` still made the deployer the owner. Direct initial ownership breaks that, so `PurchaseUniswap` now initializes the path through an internal helper; the public setter stays `onlyOwner`.

_Pre-optimizer figures (`optimizer = false`, no IR), the basis in force when this PR shipped — see [Measurement basis](./README.md#measurement-basis)._

**Runtime bytecode (EIP-170 limit 24,576) vs R44:**

| contract | R44 | R45 | grown | margin after |
|---|---|---|---|---|
| `DcaManager` | 16,307 | 16,670 | 363 | 7,906 |
| `OperationsAdmin` | 4,277 | 4,625 | 348 | 19,951 |
| `IdleDocHandlerMoc` | 10,668 | 11,055 | 387 | 13,521 |
| `LayerBankDocHandlerMoc` | 15,364 | 15,751 | 387 | 8,825 |
| `SovrynDocHandlerMoc` | 14,930 | 15,317 | 387 | 9,259 |
| `TropykusDocHandlerMoc` | 15,147 | 15,534 | 387 | 9,042 |
| `SovrynErc20HandlerDex` | 20,660 | 21,061 | 401 | 3,515 |
| `TropykusErc20HandlerDex` | 20,916 | 21,317 | 401 | 3,259 |

Handlers pick up Ownable2Step plus the canonical renounce override (~387 bytes). Dex grows 14 more from the internal path helper. Margin stays comfortable before R9.

**Storage.** Ownable2Step's `_pendingOwner` is a sequential slot (OZ v5 Ownable's `_owner` is also sequential in this pin). Every first-party contract shifts BitChill variables down one slot (`s_operationsAdmin` 1 → 2 on DcaManager; fee fields 1 → 2 on handlers). Relative order is unchanged. Fresh deployment; nothing to migrate. R18 still packs `DcaDetails` inside `s_dcaSchedules`, not these slots.

Live `registerRoute` / `assignTokenHandler` run as `onlyOwner` after construction, so they use the Foundry broadcaster as owner for that transaction. `_assertLiveBroadcastSender` reverts *before* any protocol `CREATE` if testnet is not `TESTNET_OWNER` or if mainnet tries to broadcast as the Safe. After setup, `_proposeFinalOwner` no-ops on testnet and proposes the Safe on mainnet. Add-on scripts revert on a non-zero `pendingOwner` so a mid-handoff handler cannot land on the outgoing EOA.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Ownership: testnet finishes with the broadcasting EOA as owner and zero pending; mainnet finishes with that EOA as owner and the Safe as pending until `acceptOwnership`.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Constructor changes and every extra file are named in the PR.

## ABI / deploy / cutover impact

- ABI: new `pendingOwner` / `acceptOwnership` surface and constructor `initialOwner` arguments; renounce reverts canonically.
- Scripts: live Foundry broadcasts from an EOA; testnet that EOA is owner, mainnet proposes the Safe. Add-ons refuse a pending admin/manager owner. `DeployMocAndUniswap` reverts on live (comparison harness only). A one-shot live script covering idle / Sovryn DOC / LayerBank DOC / LayerBank USDRIF / LayerBank USDT0 is cutover work after R36 / R37, not this PR.
- Cutover: ops must `acceptOwnership` from the Safe after a mainnet script, one call per contract. Later ownership changes use propose/accept. Frontend issue only if the app exposes owner transfer (not expected).
