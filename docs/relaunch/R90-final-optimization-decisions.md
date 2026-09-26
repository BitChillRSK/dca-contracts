# R90 — final optimization and handler-structure decisions

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

Make the final pre-deployment decisions on the candidates R89 deliberately left out, using Rootstock
gas, shipped artifacts, and source responsibility rather than Foundry totals alone. Implement only the
candidates the human approves after seeing the evidence in this spec; keep each approved candidate in
its own commit.

## Background

R89's whole-protocol review found several improvements but kept the executable PR bounded. A later
owner review approved removing `PurchaseRbtc.batchBuyRbtc`'s `purchaseToken` local as R89 item 14 and
asked that every remaining candidate be preserved for a later, explicit decision rather than extending
PR 154 again.

The decision bar stays the one used by R87–R89:

- removing a redundant read, check, alias, file, or misleading ownership boundary may be worthwhile at
  any size when equivalence or the numeric bound is explicit and tested;
- a change that adds state, ABI surface, unsafe access, duplicate representations, or cross-layer
  coupling needs a material recurring benefit;
- Foundry/Cancun gas is a regression pin, not a Rootstock bill. Reprice every changed `SLOAD` and
  `SSTORE` with `ROOTSTOCK-GAS-SCHEDULE.md`.

The review excludes `src/tropykus-legacy/` as a production target. A shared-base edit may still make
the legacy leaf compile differently, so the normal build gate remains authoritative; do not add or
restore a live Tropykus deployment path.

## Evidence already collected

### Dex oracle/floor packing prototype

The useful layout is not merely moving `s_mocOracle`. It narrows both 1e18-capped settings from
`uint128` to `uint64`, then declares the hot pair together:

```solidity
ICoinPairPrice internal s_mocOracle;               // 160 bits
uint64 internal s_amountOutMinimumPercent;         // same slot, offset 20
uint64 internal s_amountOutMinimumSafetyCheck;     // next slot
```

`HUNDRED_PERCENT` is `1e18`, below `type(uint64).max` (`18_446_744_073_709_551_615`), and both setters
already enforce that cap before storage. Keep checked `toUint64()` casts; this candidate does not
authorize unchecked truncation.

Measured on an isolated copy of the R89 branch under the shipping `deploy` profile, idle Dex's 10-row
batch moved **493,843 → 491,740 Foundry gas** (−2,103). That is one Cancun cold `SLOAD`, not a
2,103-gas Rootstock claim: replacing it with Rootstock's flat 200 and carrying over the remaining
compute gives approximately **−203 Rootstock gas per Dex batch**. `_getAmountOutLowerBound` runs once
per batch, not once per row.

Metadata-included runtime changes under `deploy`, on the same source pair:

| Production leaf | Runtime delta |
|---|---:|
| Idle Dex | +33 bytes |
| Sovryn Dex | +32 bytes |
| LayerBank Dex | +167 bytes |

The total storage footprint stays two slots and every field after the settings keeps its slot number.
The trade is path-specific:

- every successful Dex batch removes one `SLOAD` (about 200 Rootstock gas);
- each rare `setAmountOutMinimumPercent` or `setAmountOutMinimumSafetyCheck` call reads two setting
  slots instead of one (about +200 Rootstock gas, derived from the layout; remeasure before citing a
  final number);
- `updateMocOracle` and each individual getter keep the same storage-access count;
- ABI, events, constructor ABI, and total slot count do not change;
- these are immutable, not proxy-upgraded contracts and have not deployed, so no state migration is
  required.

Recommendation: **implement**. It makes the widths state the enforced range, co-locates the two values
the purchase needs, and charges the extra read only to rare governance setters.

### Lending zero-cash diagnostic sum

After a lending redemption returns zero cash, `_batchRetrieveStablecoin` re-sums `purchaseAmounts` only
to populate `TokenLending__ZeroStablecoinReceived`. Every row came from DcaManager's `uint96` schedule
amount, exactly the same local bound that justifies Idle's unchecked sum. An isolated prototype:

```solidity
unchecked {
    requested += purchaseAmounts[i];
}
```

reduced every lending leaf by **8 runtime bytes under `deploy`**. It changes no successful-path gas;
it only removes an impossible overflow check on the revert path.

Recommendation: **implement**. The proof is local, the source shape matches the idle sum, and no
external market behavior bounds it.

### `purchaseToken` local

R89 item 14 owns this change; do not implement it again here. The human approved using
`i_stableToken` directly for code quality even though `deploy` gas is identical and the earlier
measurement found LayerBank Dex runtime +121 bytes under `deploy` (+155 default). R90 records it only
because it motivated reopening the rest of the table.

## Candidate matrix and recommendations

| Candidate | Known effect / cost | Recommendation |
|---|---|---|
| Pack `s_mocOracle` with a narrowed live floor | ≈−203 Rootstock gas per Dex batch; +32/+33/+167 runtime bytes on the three production Dex leaves; rare floor setters ≈+200 | **Implement**, subject to reproducing the read count and artifacts. |
| `unchecked` lending zero-cash `requested` sum | No successful-path gas; −8 runtime bytes per lending leaf; locally bounded by `uint96` rows | **Implement**. |
| Pass a gross total into `_batchRetrieveStablecoin` | Avoids the idle sum and could reuse the total for the lending zero-cash error | **Keep rejected.** It gives the hook both rows and a caller-maintained claimed total that can disagree, changes every implementation/harness, and saves only tiny idle compute. |
| Remove swap-pop array-length/bounds re-reads | A few hundred gas on rare deletion | **Keep rejected.** The length is already cached; removing the remaining compiler bounds checks needs assembly/unsafe storage access, while a memory round trip costs more. |
| Fold `IdleErc20Handler` into `TokenHandler` | Deletes a very small abstract class; no state/read/check removal | **Keep rejected.** It would make idle funding the default behavior of the base that lending must override. The slim class is the useful name and proof boundary for pooled idle custody. |
| Move `FeeHandler` out of `TokenHandler` and initialize it solely through the purchase branch | Expected runtime/gas neutrality; broad constructor-chain and test churn | **Prototype, then likely implement for code quality.** Fees are calculated and paid by `PurchaseRbtc`, not deposit/withdraw custody. This removes one unnecessary shared-base edge and fee arguments from funding/protocol constructors, but only ship if concrete ABIs, layout, gas, and artifact growth remain acceptable. |
| `unchecked` exchange-rate/oracle arithmetic | One or more checks per call | **Keep checked.** Values come from markets or an oracle; a malfunction must revert rather than wrap. |
| `unchecked` falling balance deltas | One check per measured transfer/redeem/swap | **Keep checked.** The checked subtraction is the assertion that the balance moved in the required direction. |
| `unchecked` `amountSpent` allocation product | 345–753 Foundry gas per 10-row batch in R89's measurements | **Keep checked.** Its proof needs an unenforced future-token supply bound; overflow would silently corrupt event telemetry. |
| `unchecked` lending `totalSharesToRedeem` and deposit share credit | About 550 Foundry gas per 10-row lending batch for the sum; tens per deposit | **Keep checked.** Their bound is external receipt-token backing, not a width enforced by BitChill. Exact burn would not catch a wrapped total. |

The recommendations are defaults, not product decisions. The human may approve any subset, including
none, after the final prototype evidence. Do not treat a recommendation in this document as permission
to implement before the gates below are answered.

## Open product decisions

Present the candidate matrix and any refreshed measurements, then ask the human all of these together:

1. Pack the Dex oracle with the narrowed live slippage floor?
2. Make the lending zero-cash diagnostic sum unchecked?
3. Move `FeeHandler` out of `TokenHandler` if the prototype preserves concrete ABI/layout and has no
   meaningful gas or size regression?
4. Override any of the seven **keep rejected / keep checked** recommendations in the matrix?

## Scope

- [ ] Reproduce the oracle-packing gas, storage-access, layout, and artifact measurements on R90's real
  base under both profiles before asking for the product verdict.
- [ ] Measure the two governance floor setters as storage accesses and convert them to Rootstock.
- [ ] Reproduce the lending diagnostic-sum artifact delta under both profiles.
- [ ] Prototype moving `FeeHandler` off `TokenHandler` without changing any concrete constructor ABI,
  external selector, event, error, or storage slot. Compare concrete ABI/method identifiers, storage
  layout, metadata-stripped creation/runtime code, deployed size, and representative gas on all live
  idle/Sovryn/LayerBank MoC and Dex leaves.
- [ ] Present one final evidence table and obtain the human's answers to all open product decisions.
- [ ] Implement only the approved subset, one commit per candidate, and record rejected verdicts with
  their final reason.
- [ ] Update `ROOTSTOCK-GAS-AUDIT.md`, this spec's verdict section, `IMPLEMENTATION_ORDER.md`, and
  `README.md` with the measurements and decisions.

## Out of scope

- [ ] Reimplementing or reverting R89 item 14 (`purchaseToken` local); R89 owns it.
- [ ] Any live Tropykus deployment arm, route index, script, or production claim.
- [ ] Assembly or unsafe storage-array access for schedule deletion.
- [ ] Event, external function, constructor ABI, or consumer-facing error changes.
- [ ] Reopening R87's event trimming, fee sweep, redeem-balance reuse, optimizer, or purchase-path
  assembly decisions.
- [ ] Merging `TokenLending`, changing exchange-rate hooks, or altering the schedule layout.
- [ ] Deploy broadcasts, live contract interaction, or consumer-repo implementations.

## Files likely touched

Decision record and retained evidence:

- `docs/relaunch/R90-final-optimization-decisions.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`
- `docs/relaunch/ROOTSTOCK-GAS-AUDIT.md`
- a focused retained gas/read-count test under `test/gas/`

Only if approved:

- oracle packing: `src/PurchaseUniswap.sol`, `test/unit/PurchaseUniswapSettingsTest.sol`, matching Dex
  purchase/gas tests;
- lending diagnostic sum: `src/LendingErc20Handler.sol`, matching redeem/error and artifact tests;
- fee ownership: `src/TokenHandler.sol`, `src/PurchaseRbtc.sol`, `src/FeeHandler.sol`,
  `src/idle/IdleErc20Handler.sol`, `src/LendingErc20Handler.sol`, `src/PurchaseMoc.sol`,
  `src/PurchaseUniswap.sol`, the live Sovryn/LayerBank/idle leaves, and the constructor harnesses that
  fail to compile after the approved move. `script/` should not change because concrete constructor
  ABIs must remain identical.

## Required tests

Before any executable push:

```text
make check
make check-deploy
make fork-sovryn
make fork-tropykus
```

Also run the retained R90 gas/read-count suite on idle Dex, Sovryn Dex, and LayerBank Dex under default
and `FOUNDRY_PROFILE=deploy`. Add targeted assertions that:

- the oracle address and live floor occupy one word and each setter preserves its packed neighbor;
- the safety floor occupies the next word and both public getters keep their values;
- `1 ether` remains accepted and values above it retain the existing custom-error boundary;
- a successful Dex batch reads the packed word once;
- the zero-cash lending error still reports the exact requested sum;
- if fee ownership moves, every concrete ABI/method id and storage slot is unchanged, fee setters and
  purchases behave identically, and both idle and lending leaves retain the same owner immediately
  after construction.

Fork tests add no R90-specific live-state assertion unless an approved prototype reveals one; they are
the required executable-change gate.

## Success criteria

- [ ] Every candidate has a recorded human verdict; no recommendation is treated as implicit approval.
- [ ] Rootstock figures identify their exact read/write conversion; no Cancun cold-load delta is quoted
  as production gas.
- [ ] Only the approved subset is implemented, with one behavior-scoped commit per candidate.
- [ ] No concrete constructor ABI, public selector, event, error, or downstream storage slot changes.
- [ ] Every accepted numeric narrowing has an enforced bound and a boundary/layout test.
- [ ] Full local and fork gates pass before push; the PR body lists exact commands and current artifact
  deltas.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` remain unchanged.
- [ ] The oracle-packing claim is one Rootstock `SLOAD` per Dex batch, not the Foundry cold-load delta.
- [ ] Checked external-market and falling-balance arithmetic remains checked unless the human explicitly
  overrode that candidate with a new enforceable proof.
- [ ] Concrete ABI and storage-layout comparisons cover every production leaf.
- [ ] Tests match **Required tests** and files beyond the list are direct compiler/test dependencies
  named in the PR.

## ABI / deploy / cutover impact

- ABI: expected none; any candidate that changes a concrete constructor or external selector is outside
  this spec and must stop for a new product decision.
- Scripts: expected none. Concrete constructor ABI preservation is a success criterion.
- Storage: the approved oracle layout may change offsets/types inside its existing two words before
  deployment, but must not shift subsequent slots. These contracts are not proxies and have not deployed.
- Cutover: expected none. If the implemented result changes a consumer-visible ABI despite the gate,
  stop and open the required sibling issues before push rather than relabeling it as internal.
