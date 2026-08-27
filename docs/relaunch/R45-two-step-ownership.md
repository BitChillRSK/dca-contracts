# R45 — Two-step ownership and safe initial ownership

Status: **not started** · Assigned: no · Optional/further-review: no

PR 32 of the relaunch stack. Stack on R44 (PR 31). Must precede authority hardening and the ABI freeze.

## Objective

Use an acceptance-based ownership transfer on every first-party governance-owned contract, set the intended owner directly at construction, and make accidental renunciation impossible.

## Background

Single-step `transferOwnership` can permanently hand control to a typo, an address that cannot call back, or the wrong Safe. `OperationsAdmin` already forbids renunciation because freezing its add-only registry is unrecoverable; the same policy should apply consistently to `DcaManager` and handlers that own fee/oracle configuration.

OpenZeppelin v5 is already present from R44. A small shared governance base is preferable to three subtly different ownership policies. R39 supplies the handler bytecode headroom this must re-measure.

## Open product decisions

**none** — two-step future transfers, direct final owner at construction, and no renunciation on every production first-party Ownable contract.

## Scope

- [ ] Add one shared first-party governance base over OZ `Ownable2Step`; its constructor takes a nonzero `initialOwner`, and `renounceOwnership` always reverts with one canonical custom error.
- [ ] Migrate `DcaManager`, `OperationsAdmin`, and the handler ownership chain (`FeeHandler` / `TokenHandler` and concrete leaves) to that base without duplicate Ownable inheritance.
- [ ] Thread `initialOwner` through production constructors and deploy helpers. Deployments finish owned by that address immediately; they must not rely on a later broadcaster-owned `transferOwnership`.
- [ ] Test pending-owner, acceptance, wrong-caller rejection, replacement of a pending owner, zero owner rejection, and renounce rejection on manager, admin, and at least one concrete handler.
- [ ] Update deployment tests to assert both final owner and zero pending owner.
- [ ] Record selector/runtime/storage impact for every concrete handler.

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

- [ ] No production first-party contract uses single-step `Ownable` directly.
- [ ] Initial ownership is correct in the deployment transaction; future transfers require acceptance.
- [ ] Renunciation is impossible across manager, admin, and handlers.
- [ ] Every concrete contract remains below EIP-170.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Ownership is neither transiently left on the broadcaster nor silently pending after deploy.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Constructor changes and every extra file are named in the PR.

## ABI / deploy / cutover impact

- ABI: new `pendingOwner` / `acceptOwnership` surface and constructor `initialOwner` arguments; renounce reverts canonically.
- Scripts: all production deploy paths pass the intended governance owner directly.
- Cutover: ops must use propose/accept for later ownership changes. Frontend issue only if the app exposes owner transfer (not expected).
