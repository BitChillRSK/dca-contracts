# R57 — Close the DOC Dex deploy hole in `DeployDexSwaps`

Status: **not started** · Assigned: no · Optional/further-review: no

Planning lives in GitHub [#105](https://github.com/BitChillRSK/dca-contracts/pull/105). Implement in a
later `Start with R57` PR, stacked on the latest open relaunch PR. Gated on R51 /
[#103](https://github.com/BitChillRSK/dca-contracts/pull/103), which settled the routing question.
**Must land before any Dex cutover broadcast.**

## Objective

Make "Sovryn DOC is never a shipped Dex route" a property the deploy script enforces rather than a
comment that currently says the opposite. `DeployDexSwaps`' live branch still constructs a
`SovrynErc20HandlerDex` for DOC and permanently assigns it to `(DOC, SOVRYN_INDEX)`.

## Background

R51's fork table at pinned block 9198813 found the DOC/rUSDT 0.05% pool holding ~1.48 rUSDT, so every
tested size partially fills at ~0.19 DOC and splitting cannot help. That settled the route question:
**DOC buys rBTC only through MoC redemption** and may appear in a Uniswap path solely as an
intermediate hop. The shipped Dex set is LayerBank USDRIF and LayerBank USDT0.

The script does not know that. In `_deployLiveDexHandlers` the Sovryn arm is guarded only by
`isUSDRIF || isUSDT0`, so with `STABLECOIN_TYPE=DOC` on `TESTNET` / `MAINNET`:

1. `registerRoute(SOVRYN_INDEX, true)` runs unconditionally;
2. the LayerBank block is skipped — DOC is not a Dex stable;
3. the "Skipping Sovryn handler deployment" early return does not fire;
4. `networkConfig.sovrynShareToken` for DOC on mainnet is `0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1`
   (the iSUSD proxy), so the zero-address guard does not fire either;
5. it constructs `SovrynErc20HandlerDex` for DOC and calls
   `assignTokenHandler(DOC, SOVRYN_INDEX, handler)`.

Three facts make this a deploy hazard rather than untidiness:

- **DOC is the default.** `DEFAULT_STABLECOIN = "DOC"` in `script/Constants.sol`, and `_stablecoinType()`
  falls back to it. This is what an operator gets by leaving `STABLECOIN_TYPE` unset, not an exotic
  invocation.
- **The assignment is permanent.** `OperationsAdmin.assignTokenHandler` reverts
  `OperationsAdmin__HandlerAlreadyAssigned` when `(token, routeIndex)` is taken, and R13 kept handler
  assignment add-only with no reassignment path. A mis-run burns `(DOC, SOVRYN_INDEX)` for the life of
  that deployment — the same key `DeployMocSwaps` needs for the production `SovrynDocHandlerMoc`, which
  matters directly for the one-shot combined live script the README already anticipates.
- **The comment asserts the opposite.** `script/DeployDexSwaps.s.sol:113` still reads "Live dex map is
  LayerBank (USDRIF / USDT0) and Sovryn (DOC)", so the next reader is told the wrong map by the file
  they are auditing.

R37 is the precedent and the model. It retired Tropykus from the live Dex branch by making
`_deployLiveDexHandlers` revert on `Protocol.TROPYKUS` while leaving the `LOCAL` / `FORK` branch
building a Tropykus handler, so `make dex-tropykus` and `make fork-tropykus` kept working. R57 does the
same for DOC, keyed on the stablecoin rather than the lending protocol.

The DOC Dex handler contracts stay. `SovrynErc20HandlerDex` remains reachable from the `LOCAL` / `FORK`
branch, which `make dex-sovryn`, `make fork-sovryn` and `ComparePurchaseMethods` still need. Only the
live deploy arm goes, exactly as R37 kept the Tropykus leaves and their suites.

## Open product decisions

1. **Does the live Dex branch keep `registerRoute(SOVRYN_INDEX, true)`?** Once the Sovryn arm is gone
   nothing in that branch assigns a handler to `SOVRYN_INDEX`, so the call registers a route class the
   deployment never uses. **Recommend removing it**, since the shipped Dex map is LayerBank-only and a
   registered-but-empty route is the kind of latent state that invites a later mis-assignment. Removing
   it changes two existing assertions — see **Required tests**. Keep it only if a planned add-on is meant
   to attach a Sovryn handler to this same admin.

## Scope

- [ ] `_deployLiveDexHandlers` rejects DOC on the live map: revert with a named string (mirror R37's
      `"Tropykus is not on the production dex map"`; suggest `"DOC is not on the production dex map"`)
      before any `CREATE`, alongside the existing `Protocol.TROPYKUS` check.
- [ ] Delete the now-unreachable Sovryn construction/assignment arm from `_deployLiveDexHandlers`,
      including the `sovrynShareToken` zero guard and the `selectedHandler` assignment, so the live
      branch cannot grow a DOC path back by accident.
- [ ] Resolve open decision 1 for `registerRoute(SOVRYN_INDEX, true)`.
- [ ] Correct the map comment at `script/DeployDexSwaps.s.sol:113` to name LayerBank USDRIF / USDT0 only,
      and say why DOC is excluded (MoC redemption is DOC's route) rather than just that it is.
- [ ] The `LOCAL` / `FORK` branch is unchanged: `deployDocHandlerDex` keeps its `Protocol.SOVRYN` arm and
      the local branch keeps building the selected protocol's handler.
- [ ] `DeployMocSwaps` is untouched. DOC's production route is MoC at `SOVRYN_INDEX` and stays that way.

## Out of scope

- [ ] Removing `SovrynErc20HandlerDex`, `TropykusErc20HandlerDex`, or any handler test suite.
- [ ] `DeployUsdrifHandler`, `DeployLayerBankHandler`, `DeployIdleHandler`, or `DeployMocAndUniswap`.
- [ ] The one-shot combined live script the README anticipates; this PR only stops the hole.
- [ ] Re-running or re-recording R51's Dex quote-vs-floor table.
- [ ] Any `src/` change. If the fix appears to need one, that is a finding to report, not a licence.

## Files likely touched

- `script/DeployDexSwaps.s.sol`
- `test/unit/deployment/LiveDeployPathTest.t.sol`
- `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md` (status and the queue entry)

## Required tests

The live DOC arm is currently **exercised and green**, so this is a behaviour change in the test suite,
not just an addition. `LiveDeployPathTest` does not inherit `DcaDappTest` and keys only on
`LENDING_PROTOCOL` / `STABLECOIN_TYPE`, so `make moc-sovryn` (sovryn + DOC) reaches `harness.run()` today
and deploys the DOC Dex handler.

- [ ] A new `test_dexLive_revertsForDocOnTheDexMap`, modelled on `test_dexLive_revertsForTropykus`:
      `MAINNET` environment, DOC, `vm.expectRevert` on the named string, asserting the revert lands
      before any `CREATE`.
- [ ] `_skipIfDexLiveUnsupported` skips DOC, so `test_dexLive_mainnetStyle_registersRoutesThenProposes`
      no longer runs the DOC combination.
- [ ] If open decision 1 removes the route registration, update the two
      `getRouteClass(SOVRYN_INDEX) == Lending` assertions in `LiveDeployPathTest` (the MoC-live case at
      ~line 156 must keep asserting it; only the **dex**-live case at ~line 185 changes).
- [ ] Full `AGENTS.md` done-gate: `make check`, plus `make fork-sovryn` and `make fork-tropykus` before
      push. Deploy-script changes touch every lane's `LiveDeployPathTest`, so no lane may be skipped.

## Success criteria

- [ ] A live `STABLECOIN_TYPE=DOC` (or unset) `DeployDexSwaps` run reverts with the named string before
      any `CREATE`; no DOC Dex handler is constructed and `(DOC, SOVRYN_INDEX)` is never assigned.
- [ ] `grep` of the live branch shows no Sovryn handler construction or assignment.
- [ ] The map comment matches the shipped Dex set.
- [ ] `make dex-sovryn`, `make dex-tropykus`, `make fork-sovryn` and `ComparePurchaseMethods` still build
      a DOC Dex handler through the `LOCAL` / `FORK` branch.
- [ ] Every done-gate lane and both required forks pass.
- [ ] No `src/` file changed.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] The revert is before any `CREATE`, not after a partial deploy.
- [ ] Local/fork DOC Dex coverage is intact; no handler or suite was deleted.
- [ ] Protocol invariants in `AGENTS.md` still hold; none are changed by this PR.

## ABI / deploy / cutover impact

- **ABI:** none. No `src/` change, no selector, event, or storage move.
- **Deploy:** the live Dex script stops accepting DOC. Any runbook or command that omits
  `STABLECOIN_TYPE` must now set it explicitly to `USDRIF` or `USDT0`.
- **Consumers:** none. No contract interface changes, so no `swapper-bot`, `front-end`,
  `bitchill-monitoring`, or `data-api` issue is required.
