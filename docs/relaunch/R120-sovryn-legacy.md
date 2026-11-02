# R120 — Retire Sovryn to legacy

Status: **assigned** · Assigned: yes · Optional/further-review: no

Stacked on R119 ([#189](https://github.com/BitChillRSK/dca-contracts/pull/189)).

## Objective

Make Sovryn what Tropykus already is: a test-only adapter outside the audit scope that no deploy
script can put on a live network. Move its sources to `src/sovryn-legacy/`, make both live deploy
branches reject it, leave route index 2 unused, and take its lanes out of the required gates. The
handler contracts and their tests stay.

## Background

Sovryn delayed iToken withdrawals behind a queue (SIP-0096, 2026-10-26) and paused the protocol after
the 2026-10-31 swap converter registry exploit. At the chain tip every iToken call reverts. R119 pinned
`make fork-sovryn` to block 9325651 so the lane still runs.

`DeployFinal` already deploys no Sovryn handler and leaves route 2 unregistered, but the rest of the
repo still treats Sovryn as a retained production adapter:

- `DeployMocSwaps`' testnet and mainnet branch registers route 2 and deploys and assigns a
  `SovrynDocHandlerMoc`; `DeployDexSwaps`' live branch registers route 2 as a lending route.
- `SOVRYN_INDEX` lives in `script/Constants.sol`, so any script can name it.
- `AUDIT_GUIDE.md` keeps `src/sovryn/` in scope "for a possible future integration".
- `make check`, `make ci`, `make check-deploy` and CI run `moc-sovryn`, `dex-sovryn` and
  `invariants-sovryn`; the push gate requires `make fork-sovryn`.
- The stateful suites run on Sovryn: `InvariantTest` supports only Tropykus and Sovryn, and
  `LendingPurchaseConservationInvariantTest` is built on `SovrynDocHandlerMoc`.

[R37](./R37-retire-tropykus-live-paths.md) did the same for Tropykus. Its reasoning applies unchanged:
a sentinel index enforces nothing; keeping the index constant out of `script/`'s compile scope does.

## Open product decisions

**none** — decided 2026-11-02 by the owner: Sovryn is dropped from the deployment and the audit scope
and renamed `sovryn-legacy`, like Tropykus. It is reconsidered only if Sovryn recovers. Route index 2
stays unused so it is never reinterpreted as another venue. The legacy lanes stay runnable but leave
the required gates, as Tropykus's did.

## Scope

- [ ] `git mv src/sovryn src/sovryn-legacy`; `git mv` the dedicated tests
      `test/ai-generated/unit/sovryn/` and `test/unit/sovryn/` to `sovryn-legacy/`. Update imports.
- [ ] `uint256 constant SOVRYN_INDEX` moves from `script/Constants.sol` to `test/Constants.sol`.
      `SOVRYN_STRING` stays: the helper configs and `DeployBase` read it to select mocks for the local
      `LENDING_PROTOCOL=sovryn` lane.
- [ ] `DeployMocSwaps` and `DeployDexSwaps`: the testnet and mainnet branches revert on
      `Protocol.SOVRYN`, register no route 2, and deploy no Sovryn handler. The local and fork
      branches still build one.
- [ ] Deployment tests assert a live run leaves route 2 unregistered and reverts for Sovryn.
- [ ] `InvariantTest` gains a LayerBank arm (`LENDING_PROTOCOL=layerbank`) over the LayerBank mocks;
      `make invariants-layerbank` replaces `invariants-sovryn` in the gates.
- [ ] `LendingPurchaseConservationInvariantTest` runs on `LayerBankDocHandlerMoc` instead of
      `SovrynDocHandlerMoc`.
- [ ] `make check`, `make ci`, `make check-deploy` and `.github/workflows/test.yml` drop `moc-sovryn`,
      `dex-sovryn` and `invariants-sovryn`. The push gate drops `make fork-sovryn`; run it only when a
      change touches `src/sovryn-legacy/`.
- [ ] `AUDIT_GUIDE.md`: `src/sovryn-legacy/` is out of scope, route 2 is unused, the exit-fee
      assumption leaves, and the release gates drop `make fork-sovryn`.
- [ ] `AGENTS.md`, `README.md`, `ADDRESSES.md`, `docs/relaunch/TASK_TEMPLATE.md` and
      `script/Constants.sol`'s index-map comment state the new facts. Earlier specs keep the paths they
      landed with; R119's decision 5 (the Sovryn adapter implements the exit hook) still holds.

## Out of scope

- [ ] Deleting `src/sovryn-legacy/` or its tests.
- [ ] Removing the `moc-sovryn` / `dex-sovryn` / `fork-sovryn` / `invariants-sovryn` lanes or the
      `probe-sovryn-exit-fee` probe.
- [ ] Any behavior change to a handler, `DcaManager` or `OperationsAdmin`.
- [ ] The Fizz suite (`test/fizz/`): it is the published Pashov fuzzing artifact and keeps its own
      fixture; only its import path changes.
- [ ] `--broadcast` or live-chain interaction.

## Files likely touched

- `src/sovryn/` → `src/sovryn-legacy/` (moves only)
- `script/Constants.sol`, `test/Constants.sol`, `script/DeployMocSwaps.s.sol`,
  `script/DeployDexSwaps.s.sol`, and comments in `script/DeployLayerBankHandler.s.sol`
- `test/unit/deployment/LiveDeployPathTest.t.sol`
- `test/ai-generated/fuzz/Invariants.t.sol`, `test/ai-generated/fuzz/LendingPurchaseConservationInvariant.t.sol`,
  `test/ai-generated/fuzz/README_INVARIANTS.md`
- Every test importing `src/sovryn/` (compiler lists them)
- `Makefile`, `.github/workflows/test.yml`
- `AGENTS.md`, `AUDIT_GUIDE.md`, `README.md`, `ADDRESSES.md`, `docs/relaunch/TASK_TEMPLATE.md`

## Required tests

```
make check
make check-deploy
make invariants-layerbank
make moc-sovryn
STABLECOIN_TYPE=USDRIF make dex-sovryn
make invariants-sovryn
make fork-layerbank
make fork-sovryn
```

Assert:

- `grep -rn "SOVRYN_INDEX" script/` is empty.
- A live `DeployMocSwaps` or `DeployDexSwaps` run leaves route 2 `Unregistered` and reverts for
  `LENDING_PROTOCOL=sovryn`.
- The legacy Sovryn lanes keep passing; the Sovryn fork lane stays pinned.
- `invariants-layerbank` runs every action, including in-kind exits, against the LayerBank wrapper.

## Success criteria

- [ ] No `script/` file can name a Sovryn route index — enforced by the compiler.
- [ ] No live deploy branch constructs a Sovryn handler; both live branches revert on `Protocol.SOVRYN`.
- [ ] The required gates run no Sovryn lane; CI's invariant lane runs on a shipped adapter.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold — this PR should not touch any of them.
- [ ] The `src/` moves are pure moves (no content change).
- [ ] No unrelated refactors.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: the live branches of `DeployMocSwaps` and `DeployDexSwaps` stop registering route 2 and
  reject Sovryn. `DeployFinal` is unchanged.
- Cutover: route 2 has no handler at launch and stays unused. Consumers that list Sovryn as a venue or
  hardcode `2 = Sovryn` for the relaunch stack must drop it.
