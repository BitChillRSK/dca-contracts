# R71 — Final pre-deployment hardening and release truthfulness

Status: **source phase in review; phases 3–5 split out** · Assigned: yes · Optional/further-review: no · Order: after R70, before any final deployment · Implementation PR: [#128](https://github.com/BitChillRSK/dca-contracts/pull/128)

[#128](https://github.com/BitChillRSK/dca-contracts/pull/128) ships the **source phase only** (gates 1–4 answers + MoC / batch-event / Dex-keep `src/` work and tests). Licensing, deferred here, is answered and implemented in [R72](./R72-licensing.md). Phases 3–5 below (deploy script, Slither, public-doc truthfulness) are split into [R73](./R73-deploy-slither-release-docs.md) — not new work, the same phases this file already scoped, given their own spec so #128 could ship and be reviewed on its own.

## Objective

Close the remaining pre-deployment gaps that have a concrete security, integration, or release-quality
payoff: settle the Dex authority dependency and lending batch-event ambiguity, verify MoC's required
redemption sequence and error boundary, ship and test one final production deployment path, run the
shipping bytecode through the static-analysis/release gates, and make public security documentation
accurately describe the code being deployed. This is the final bounded cleanup, not a new architecture
generation.

## Background

### 1. `minRbtcOut == 0` is not a special on-chain safety boundary

Uniswap uses `max(minRbtcOut, oracleFloor)`. Consequently every caller minimum at or below the oracle
floor has identical execution semantics; rejecting exactly zero would catch one spelling of a loose
quote while accepting `1`, which is economically the same. Zero remains a useful explicit sentinel for
"use the venue floor only". The bot should normally submit a quote-tight value, and monitoring may flag
zero or a caller minimum below the computed floor, but R71 adds no zero-only revert.

### 2. A purchase pause is not justified by third-party failure alone

If a venue call reverts, the bot's simulation prevents a broadcast and the transaction would roll back
atomically even without a pause. An on-chain purchase pause is different only when a call would succeed
inside current bounds but governance wants it stopped: for example, incident containment after an
unexpected but non-reverting venue behavior, a compromised operator, or state moving between simulation
and inclusion. BitChill already bounds those cases with `onlySwapper`, swapper revocation, the Uniswap
oracle floor, caller min-out, full-input/intermediate-balance checks, exact lending-share consumption,
and bot simulation. A pause would add a registry read to every successful handler batch forever.

R71 therefore adds no purchase circuit breaker. Revisit only if operations later require independent
on-chain disablement of one route while other routes continue under the same swapper. A bot-side
disabled-route switch is the proportionate operational control today.

### 3. The handler diamond is a source-level coupling cost, not a runtime defect

Dex lending leaves inherit a funding branch and `PurchaseUniswap`; both reach `FeeHandler`,
`DcaManagerAccessControl`, and `StablecoinSource`. Solidity
[C3-linearizes the graph](https://docs.soliditylang.org/en/v0.8.35/contracts.html#multiple-inheritance-and-linearization):
shared bases occur once in the deployed storage layout, and
[base code is compiled into one created contract](https://docs.soliditylang.org/en/v0.8.35/contracts.html#inheritance),
whose internal calls use jumps rather than external message calls. The current design is therefore
compact and gas-efficient.

The real cost is reviewability. `PurchaseUniswap`'s constructor dynamically calls `_purchaseToken()`, so
the concrete leaf must list and initialize the funding base first. Purchase behavior also relies on a
sibling branch to initialize shared fee/access state. Constructor obligations leak into test harnesses,
and a future change to a shared base must be checked against the whole linearization. This is
maintainability debt, but these contracts are immutable and not storage-layout-compatible proxies, so a
late flattening would create much more audit surface than it removes.

For a future generation, prefer one stateful `HandlerBase` that owns stablecoin custody, DcaManager
authority, fee configuration, and rBTC books; derive one lending base from it; implement each venue with
internal hooks or stateless internal libraries. That yields a tree rather than a diamond. Do not split
funding and purchasing into separately deployed adapter contracts merely to claim composition: external
calls add ABI copying, call/reentrancy boundaries, deployments, approvals, and another address whose
code and custody must be trusted. [Internal library functions](https://docs.soliditylang.org/en/v0.8.35/contracts.html#libraries)
are compiled into the caller and are useful for stateless math/encoding; they do not naturally own
modifiers or storage-heavy virtual workflows. Public/external library functions use `DELEGATECALL` and
are not the desired seam here.

R71 records that architecture for future work and does not refactor the current hierarchy.

### 4. The Dex authority dependency has two defensible shapes

`PurchaseUniswap.setPurchasePath` currently reaches the swapper allowlist through its immutable
`i_dcaManager`, whose `i_operationsAdmin` is itself immutable. Caching that same admin in every Dex
handler would save one external view hop on a rare path-change transaction, but it would duplicate
authority state, add a handler getter and constructor wiring, and create no new security boundary. The
current dependency is explicit in the call site and cannot drift while DcaManager is immutable.

Keeping that traversal is defensible because it preserves one authority root and the extra call occurs
only when changing a path, not on purchases. Pinning the admin is also defensible if it is resolved from
the constructor-supplied manager rather than supplied independently: it makes the dependency direct and
removes the runtime hop, but duplicates immutable authority state and adds base-constructor/getter
surface. Neither choice fixes an exploit. R71 leaves the choice to the implementer and human after the
actual code/ABI/gas delta is shown; it must not present source-level neatness as a security finding.

### 5. Batch lending logs mix planned principal and measured cash

`TokenLending__SharesRedeemed` reports measured stablecoin on a single redeem, but the batch path emits
the same event before the protocol call with each row's planned gross amount. No field name can make
both meanings honest. The batch already emits the canonical facts without inventing per-user cash:
`TokenLending__UserSharesUpdated` records each exact virtual-share debit,
`TokenLending__SharesRedeemedBatch` records measured total cash and shares, and
`PurchaseRbtc__RbtcBought.amountSpent` attributes measured net stablecoin to each purchase row.

The observation is valid, but the remedy is not yet agreed. Removing the batch-path emission is the
smallest implementation because the exact per-user share debit and measured batch cash already have
canonical events. It is nevertheless a consumer-visible change and must not be treated as decided merely
because it saves gas. The alternative is to emit a post-redeem pro-rata measured-cash attribution per
user; that preserves a per-user redemption event but adds a second loop and reports an allocation, not an
independently observed per-user payout. Merely renaming or documenting the current field leaves one event
parameter with two meanings and does not close the finding.

R71 keeps this as an open product decision. No implementation may silently remove the event or choose an
allocation rule.

### 6. `PurchaseMoc` needs an evidence-based redemption and error-boundary decision

`PurchaseMoc._redeemDoc` currently calls `redeemDocRequest` and then `redeemFreeDoc`, wrapping each in a
bare `try`/`catch` that replaces every downstream revert with a parameterless BitChill error. The catches
are atomic, but atomicity alone does not justify them: because BitChill neither recovers nor selects a
fallback, the original MoC revert data may be more useful to the bot during simulation and to incident
diagnosis than a stable phase label.

Before changing this path, inspect authoritative MoC documentation/source for the deployed Rootstock
version and prove on a current fork whether `redeemDocRequest` is required before `redeemFreeDoc`, what
state each call changes, whether either call can return success without performing the expected action,
and which revert formats the live proxy produces. Do not preserve the first call merely because the old
BitChill code used it, and do not remove it from recollection alone.

The defensible error choices are: direct high-level calls that naturally bubble original revert data;
or a catch carrying the original `bytes` inside a stage-specific custom error when stable phase identity
is worth an ABI change. The current parameterless replacement is acceptable only if the implementation
records why discarding the original reason is operationally preferable. Separate `Error(string)`,
`Panic(uint256)`, and low-level catches are unjustified unless BitChill reacts differently to them.

Do not add `try`/`catch` around other venue or lending calls merely for consistency. Direct failure
propagation is preferable where BitChill has no fallback behavior or stable classification to add.
Compound-style non-zero return codes and non-standard ERC-20 returns continue to use their existing
explicit checks / `SafeERC20`; those are not exception-handling cases.

### 7. The release surface is not yet represented by one production deployment

The current live scripts construct separate stacks, while the README says the final one-shot deployment
of one `OperationsAdmin` / one `DcaManager` with DOC, USDRIF, and USDT0 handlers is still a follow-up.
R71 owns that script and its deployment tests. It must use the final route map, explicit per-token mins,
the deploy profile, fail-closed environment validation, two-step ownership handoff, and post-deployment
assertions. It must not broadcast from an agent session.

### 8. Public security claims describe an older codebase too broadly

The two published reports are valuable historical reviews, but both predate the 2026 relaunch stack and
were performed by the same auditor. `audits/README.md` currently describes them as multiple rigorous
independent audits, says all findings remain resolved, and summarizes mitigations that later changed
(including stuck-fund recovery and the old schedule-id model). `README.md` also repeats a stale
OpenZeppelin version and old installation path. `SECURITY.md` promises patches/backports that immutable
deployments cannot receive and states a final license while licensing is open.

High-end release documentation should be precise, not promotional: name report dates, scope/commit when
known, distinguish historical audit coverage from the final relaunch diff, describe immutable incident
response as redeploy/new route plus user exit, and make no reward or license promise that is not settled.

## Open product decisions

Answered 2026-09-07 (source phase). License, deferred here, is answered 2026-09-07 and implemented in [R72](./R72-licensing.md) (BUSL-1.1, 4-year term, `GPL-2.0-or-later` change license).

1. **License/SPDX — answered in [R72](./R72-licensing.md), not this PR.** Deferred here as planned;
   the SPDX sweep and the GPL-import compliance gap this section originally flagged as a reason to
   defer are both closed there.
2. **Dex OperationsAdmin dependency — (a).** Keep
   `PurchaseUniswap -> immutable DcaManager -> immutable OperationsAdmin`. Path changes are rare;
   one authority root beats duplicated immutable admin state.
3. **Batch `TokenLending__SharesRedeemed` — stop emitting on the batch path.** Rely on
   `UserSharesUpdated` (exact per-row share debit) plus `SharesRedeemedBatch` (measured totals).
   Keep the single-user `_redeemShares` emission: there `underlyingAmount` is measured cash after
   the protocol call. Update NatSpec so the field has one meaning.
4. **MoC — `redeemFreeDoc` only; bubble original reverts.** Evidence lives in
   `test/mainnet-debug/moc-redeem-free-doc/` (`make probe-moc-redeem-free-doc`): free DOC redeems
   without a prior `redeemDocRequest`, and the request path does not pay immediate rBTC. Drop the
   request call and both parameterless `try`/`catch` wrappers; delete `IPurchaseMoc`. Zero measured
   rBTC still fails closed in `PurchaseRbtc`.
5. **Sovryn 0.1% exit fee — disclose in the front-end if/when Sovryn ships (answered 2026-09-07).**
   Tip burns already haircut ~10 bps (probe evidence); BitChill still measures cash (R1). Human: Sovryn
   may or may not be on the relaunch map. Do **not** treat this as an urgent live-UI change. When (if)
   a Sovryn route is offered after cutover, the front-end should tell users exits cost ~0.1%. Tracked as
   [front-end#25](https://github.com/BitChillRSK/front-end/issues/25).

No other product gate on the source phase. In particular, keep `minRbtcOut == 0` valid, add no purchase
pause, and do not refactor the handler inheritance graph.

## Ops checks (not Solidity)

- **Standing `redeemDocRequest` settlements from the live (pre-relaunch) handlers — closed, no
  action (answered 2026-09-07).** Old BitChill MoC handlers called `redeemDocRequest` before every
  purchase. The open question was whether any of those handler-address queue entries ever settled
  (or still can) against live MoC, and whether any DOC is stranded waiting on settlement. Answered:
  the protocol has run this exact call pattern for close to two years with no reported issue, which
  is itself the evidence — a materially-sized standing request settling unexpectedly, or DOC going
  stranded, would have surfaced by now. No further ops investigation is required before cutover.
  This does not change gate 4 above: the *relaunch* contracts still should not make this call, for
  the reasons gate 4 gives independent of this history.

## Mandatory implementation order

Everything that can change a first-party `src/` file must be investigated, decided, implemented, and
tested **before** work begins on deployment scripts, release reports, runbooks, or public-document
cleanup. R71 is ordered in these phases:

1. Resolve all four source-affecting gates above, including the license/SPDX treatment, the
   authoritative/live MoC evidence, and concrete OperationsAdmin variants. Present the defensible
   technical choices and obtain the human answers; do not edit `src/` while one remains unanswered.
2. Implement every resulting change under `src/` and `src/interfaces/`, plus its focused mocks and tests.
   Complete targeted tests, interface parity, event/error indexing checks, ABI comparison, and relevant
   fork proof. Freeze the source-level design before continuing.
3. Only then implement the canonical deployment script and deployment tests against that frozen source.
4. Run Slither, full release-artifact/size/storage checks, and the full local/fork gates.
5. Last, update README/audit/security prose, the runbook, release record, consumer issues, and PR body to
   describe the code that actually passed the gates.

Do not interleave public-doc cleanup or final deployment scripting with unresolved `src/` decisions; a
later source choice would invalidate their claimed ABI, addresses, tests, and release evidence.

## Scope

- [ ] Measure and resolve the Dex OperationsAdmin dependency according to its product gate. Preserve one
      immutable authority graph and existing owner/swapper authorization under either option; document
      the rejected variant and its measured delta.
- [ ] Resolve `TokenLending__SharesRedeemed` according to the answered product gate. In either design,
      update interface NatSpec, tests, and monitoring cutover notes so a consumer cannot mistake planned
      principal for measured cash. Keep event indexing unchanged and add no redundant share-balance event.
- [ ] Research and resolve the MoC call sequence and error propagation according to its product gate.
      Add focused tests for every retained call, original-revert preservation or intentional wrapping,
      zero-output protection, and complete rollback. Add a current Rootstock fork proof of the chosen
      sequence; do not add fallback/continue behavior or blanket catches to unrelated integrations.
- [ ] Add a one-shot final live deployment script that creates one admin and manager, registers the final
      route classes once, sets explicit raw-unit mins for DOC/USDRIF/USDT0 before assigning handlers,
      deploys the final production handler map, proposes the final Safe owner on every ownable contract,
      allowlists the explicitly configured non-zero initial swapper before ownership handoff, and
      returns/logs every address needed for verification and consumer configuration. The live map is
      exactly DOC idle/LayerBank/Sovryn through MoC plus USDRIF and USDT0 idle/LayerBank through
      Uniswap: seven handlers total. Unknown network addresses, unsupported token/venue combinations,
      wrong chain/environment, zero owner/collector/swapper, or incomplete handler maps must revert
      rather than warn and continue.
- [ ] Add deployment tests that construct the whole final stack through that script and assert route
      class, handler uniqueness, stablecoin/receipt token wiring, min amounts, fee bands, oracle/path,
      owner/pending-owner state, swapper state, and interface support. Keep existing component scripts for
      local/fork tests; mark which script is canonical for the real deployment.
- [ ] Run `make slither`, triage every result against the final diff, fix actionable first-party findings,
      and document narrowly justified suppressions in `slither.config.json` or an R71 results section.
      Do not perform broad refactors merely to silence style/complexity detectors.
- [ ] Run a final ABI/event/storage-layout comparison and deployed-bytecode size report for every
      deployable contract. Expected constructor/event changes must be enumerated; unexplained changes
      block release. Store the reproducible commands and final commit hash in the release record.
- [ ] Correct `README.md`, `audits/README.md`, and `SECURITY.md`: current OpenZeppelin pin and repository
      install path; audit dates/auditor/scope and historical status; explicit statement that the final
      relaunch stack has not received an independent audit unless that changes; immutable-contract patch
      policy; factual disclosure/reward language; and the chosen license only after the gate is answered.
- [ ] Update the deployment runbook with preflight, simulation, deploy-profile, verification,
      ownership-acceptance, swapper activation, consumer-address publication, and rollback/abort checks.
      Commands may be documented but an agent must not broadcast.
- [ ] Human release proof before mainnet: deploy the exact final commit with
      `FOUNDRY_PROFILE=deploy` to Rootstock testnet and verify representative manager/admin/MoC/Dex
      artifacts on Blockscout. Record transaction, address, compiler settings, and verification links.

## Out of scope

- [ ] Rejecting `minRbtcOut == 0`; a monitoring rule may flag it, but values below the oracle floor are
      intentionally equivalent on chain.
- [ ] A purchase/venue circuit breaker.
- [ ] Fee-on-measured-cash redesign. The fee-on-planned-gross policy remains explicit and covered by
      exact-share-consumption tests.
- [ ] Diamond flattening, external adapter composition, delegatecall modules, or storage namespaces.
- [ ] Upgradeable proxies or migration hooks.
- [ ] A third independent audit. R71 must describe the audit boundary honestly; obtaining a new audit is
      a separate human/vendor engagement.
- [ ] Owner rescue of pooled tokens or rBTC.
- [ ] `forge fmt` of existing files.
- [ ] Mainnet or testnet broadcast by an agent.

## Files likely touched

- `src/PurchaseUniswap.sol`
- `src/interfaces/IPurchaseUniswap.sol` (only if the chosen dependency shape changes its surface)
- Dex leaf/base-initializer call sites (only if the chosen dependency shape requires them)
- `src/LendingErc20Handler.sol`
- `src/interfaces/ITokenLending.sol`
- `src/PurchaseMoc.sol`
- `src/interfaces/IPurchaseMoc.sol`
- `test/mocks/MockMocProxy.sol`
- Focused MoC purchase tests under `test/unit/`
- `script/DeployBase.s.sol`
- `script/DeployDexSwaps.s.sol`
- `script/DeployMocSwaps.s.sol`
- `script/DeployUsdrifHandler.s.sol`
- `script/DeployLayerBankHandler.s.sol`
- `script/DeployFinal.s.sol` (new canonical live stack; final name may follow existing naming)
- `test/unit/LendingErc20HandlerRedeemTest.t.sol`
- `test/unit/PurchaseUniswapSettingsTest.sol`
- `test/unit/deployment/BaseDeploymentTest.t.sol`
- `test/unit/deployment/FinalDeploymentTest.t.sol` (new)
- Direct Dex-leaf constructor call sites under `test/`
- `slither.config.json`
- `README.md`
- `audits/README.md`
- `SECURITY.md`
- `docs/relaunch/README.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

Targeted first:

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract LendingErc20HandlerRedeemTest
SWAP_TYPE=dexSwaps LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=USDRIF forge test --match-contract PurchaseUniswapSettingsTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-test 'test_.*RedeemDoc'
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract FinalDeploymentTest
make slither
```

Behaviors to assert:

- `setPurchasePath` preserves owner and authorized-swapper behavior under the chosen authority shape;
  arbitrary callers still revert and no independently supplied admin can disagree with DcaManager.
- A single lending redeem emits `SharesRedeemed` with measured cash. The chosen batch-event design has
  one documented meaning, exact `UserSharesUpdated` debits, one measured `SharesRedeemedBatch`, and no
  planned value presented as measured cash.
- The chosen MoC sequence is proven against the deployed protocol version. Every retained call has the
  selected revert-data behavior, zero rBTC still fails closed, and every earlier state change rolls back.
- The final deployment produces exactly the intended token × route map, no Tropykus live handler, no
  DOC Dex handler, and no Sovryn handler for an unsupported stable.
- Every listed token has its explicit decimal-correct min before its first assignment.
- Every ownable deployment ends with the intended current owner/pending-owner combination; no component
  is accidentally left controlled by the script or an untracked EOA.
- All configured token, receipt-token, router, WRBTC, oracle, MoC, fee collector, path, and route values
  match the selected network config and are non-zero where required.

Full gates before push: `make check`, `make check-deploy`, `make fork-sovryn`,
`make fork-tropykus`, and `make fork-dex-path`. R71 adds final-deployment assertions to normal lanes;
the human testnet proof is an additional release gate, not a substitute.

## Success criteria

- [ ] Dex path authority follows the selected, measured immutable dependency shape, with no mismatch
      possibility and no accidental hot-purchase-path cost.
- [ ] `TokenLending__SharesRedeemed` has one documented meaning under the chosen batch-event design.
- [ ] MoC's minimum necessary call sequence is supported by authoritative/live evidence; revert data is
      preserved or intentionally wrapped according to the answered gate, with explicit rollback tests.
- [ ] One fail-closed script and test suite construct the complete intended production deployment.
- [ ] Slither has no unexplained actionable first-party finding.
- [ ] ABI, event, storage, bytecode-size, and compiler-profile release reports are reproducible and clean.
- [ ] Public docs state the current dependency versions, immutable upgrade model, and historical audit
      boundary accurately.
- [ ] The license/SPDX gate is answered and consistently applied.
- [ ] The exact final `via_ir` commit is deployed on Rootstock testnet and representative artifacts verify
      on Blockscout before mainnet.
- [ ] All local, deploy-profile, invariant, fork, and final-deployment tests pass.
- [ ] Consumer issues are opened/updated and linked from the implementation PR.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests match **Required tests**.
- [ ] Every final live handler is created through the canonical script; no duplicate independent stack.
- [ ] Static-analysis suppressions explain a false positive precisely and are not directory-wide escapes.
- [ ] Audit prose distinguishes the reviewed 2025 commits/scope from the 2026 relaunch contracts.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: Dex-handler getter/constructor impact, lending-event impact, and MoC custom-error impact all depend
  on the answered source gates. Enumerate the chosen changes and rejected alternatives before the source
  phase closes; regenerate downstream ABI only after that phase is frozen.
- Scripts: new canonical final deployment; existing component scripts remain for tests/add-ons only and
  must not be presented as independent production stacks.
- Cutover: update `bitchill-monitoring` for the chosen event rule/meaning and regenerated ABI/docs;
  update `front-end`, `swapper-bot`, `data-api`, `metrics-dashboard`, and monitoring with the one-stack
  address/route manifest where their existing deployment configuration requires it. Search existing
  issues before creating duplicates, per `AGENTS.md`.
