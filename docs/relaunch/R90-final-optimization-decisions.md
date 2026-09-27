# R90 — final optimization and handler-structure decisions

Status: **in progress** · Assigned: [PR #155](https://github.com/BitChillRSK/dca-contracts/pull/155) · Optional/further-review: no

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

## Evidence reproduced on R90 base (2026-09-27)

Base: `perf/r89-post-r88-review-candidates` @ `46bb8a8` (PR #154 head). Profiles: `[profile.default]`
and shipping `[profile.deploy]`. Rootstock conversions use flat `SLOAD = 200`
(`ROOTSTOCK-GAS-SCHEDULE.md`); Foundry cold-load deltas are regression pins only.

### Dex oracle/floor packing

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Idle Dex 10-row batch Foundry gas (`deploy`) | 493,843 | 491,740 | −2,103 |
| Same batch, Rootstock (replace one cold SLOAD 2,100 → 200; carry compute) | — | — | ≈ **−203** |
| Idle Dex runtime (`deploy`, metadata-included) | 9,806 | 9,839 | **+33** |
| Sovryn Dex runtime (`deploy`) | 12,828 | 12,860 | **+32** |
| LayerBank Dex runtime (`deploy`, IR artifact) | 13,092 | 13,259 | **+167** |
| Default-profile Dex runtimes | 12,643 / 16,396 / 16,653 | 12,653 / 16,406 / 16,663 | **+10** each |

Layout after packing (idle; lending inserts `s_shares` at 4 and shifts by one):

- slot N: `s_mocOracle` (20) + `s_amountOutMinimumPercent` `uint64` (8)
- slot N+1: `s_amountOutMinimumSafetyCheck` `uint64` (8)
- `s_swapPath` and later fields keep their slot numbers

State-diff on a successful idle Dex batch: packed oracle+percent word **1 read under
`deploy`/`via_ir`**, **2 reads under default/legacy** (one SLOAD per field even when packed);
safety word **0 reads**. The ≈−203 Rootstock saving is therefore on the **shipping** artifact only.
Each floor setter reads both setting words (was one shared word for both `uint128`s) → rare
governance path ≈ **+200 Rootstock** per setter. Checked `toUint64()` retained; `1 ether` still
accepted; values above it keep the existing custom errors.

### Lending zero-cash diagnostic sum

`unchecked { requested += purchaseAmounts[i]; }` on the revert-only path under `deploy`:

| Leaf | Before | After | Delta |
|---|---:|---:|---:|
| SovrynDocHandlerMoc | 8,532 | 8,524 | **−8** |
| LayerBankDocHandlerMoc | 8,788 | 8,780 | **−8** |
| TropykusDocHandlerMoc | 8,764 | 8,756 | **−8** |
| IdleDocHandlerMoc | 5,242 | 5,242 | 0 (no lending path) |

No successful-path gas change. Same `uint96` row bound as Idle's unchecked sum.

### FeeHandler ownership move (prototype)

Moved `FeeHandler` off `TokenHandler` onto `PurchaseRbtc` (fee args routed through `PurchaseMoc` /
`PurchaseUniswap`). Concrete leaf constructor parameter lists unchanged.

| Check | Result |
|---|---|
| Storage layout (IdleDoc / SovrynDoc under default; Idle Dex under `deploy`) | **Identical** slot/offset/type vs R89 base |
| `[profile.deploy]` (`via_ir`) | Dex leaves compile; layout preserved |
| `[profile.default]` (`via_ir = false`, what `make check` uses) | **`IdleErc20HandlerDex` stack-too-deep** at the leaf constructor |
| Test/script churn | Every abstract-base test harness that constructs `IdleErc20Handler` /
`LendingErc20Handler` / protocol adapters must drop fee args; leaves stay ABI-stable |

Updated recommendation: **reject** unless the human accepts either (a) making day-to-day `make check`
depend on via-IR for Dex leaves, or (b) a further constructor/stack refactor beyond this candidate's
scope. Layout and shipping-profile compile are fine; the default-profile stack break is the blocker.

### `forge fmt`

`forge fmt --check` reports **118** files needing changes: **19** `src/`, **89** `test/`, **10**
`script/`. Diffs are whitespace/wrapping (including trailing blank lines and multi-line returns). No
fight with section-banner conventions spotted in the sample; a format-only commit would still need the
R85 metadata-stripped bytecode identity check on every touched `src/` file.

## Candidate matrix and recommendations

| Candidate | Known effect / cost | Recommendation |
|---|---|---|
| Pack `s_mocOracle` with a narrowed live floor | ≈−203 Rootstock gas per Dex batch; +32/+33/+167 runtime bytes on the three production Dex leaves; rare floor setters ≈+200 | **Implement**, subject to reproducing the read count and artifacts. |
| `unchecked` lending zero-cash `requested` sum | No successful-path gas; −8 runtime bytes per lending leaf; locally bounded by `uint96` rows | **Implement**. |
| Pass a gross total into `_batchRetrieveStablecoin` | Avoids the idle sum and could reuse the total for the lending zero-cash error | **Keep rejected.** It gives the hook both rows and a caller-maintained claimed total that can disagree, changes every implementation/harness, and saves only tiny idle compute. |
| Remove swap-pop array-length/bounds re-reads | A few hundred gas on rare deletion | **Keep rejected.** The length is already cached; removing the remaining compiler bounds checks needs assembly/unsafe storage access, while a memory round trip costs more. |
| Fold `IdleErc20Handler` into `TokenHandler` | Deletes a very small abstract class; no state/read/check removal | **Keep rejected.** It would make idle funding the default behavior of the base that lending must override. The slim class is the useful name and proof boundary for pooled idle custody. |
| Move `FeeHandler` out of `TokenHandler` and initialize it solely through the purchase branch | Layout preserved; deploy profile compiles; **default profile stack-too-deep on Dex leaves** | **Reject** (updated after prototype). |
| `unchecked` exchange-rate/oracle arithmetic | One or more checks per call | **Keep checked.** Values come from markets or an oracle; a malfunction must revert rather than wrap. |
| `unchecked` falling balance deltas | One check per measured transfer/redeem/swap | **Keep checked.** The checked subtraction is the assertion that the balance moved in the required direction. |
| `unchecked` `amountSpent` allocation product | 345–753 Foundry gas per 10-row batch in R89's measurements | **Keep checked.** Its proof needs an unenforced future-token supply bound; overflow would silently corrupt event telemetry. |
| `unchecked` lending `totalSharesToRedeem` and deposit share credit | About 550 Foundry gas per 10-row lending batch for the sum; tens per deposit | **Keep checked.** Their bound is external receipt-token backing, not a width enforced by BitChill. Exact burn would not catch a wrapped total. |

The recommendations are defaults, not product decisions. The human may approve any subset, including
none, after the final prototype evidence. Do not treat a recommendation in this document as permission
to implement before the gates below are answered.

## Open product decisions

Human answers (2026-09-27), locked for this PR:

1. Pack the Dex oracle with the narrowed live slippage floor? **Yes — implemented** (`1b54321`,
   `0883bb7`).
2. Make the lending zero-cash diagnostic sum unchecked? **Yes — implemented** (`cdd7d73`).
3. Move `FeeHandler` out of `TokenHandler`? **Deferred to a dedicated follow-up PR** (approved to
   implement for diagram cleanup; default-profile Dex stack-too-deep must be solved there, not here).
4. Override keep-rejected / keep-checked rows?
   - Gross total into `_batchRetrieveStablecoin`: **keep rejected.**
   - Swap-pop bounds: **still open** — human asked to see the candidate code before deciding; not in
     this PR either way.
   - Fold `IdleErc20Handler`; keep-checked market/delta/`amountSpent`/lending-share arithmetic:
     **no override — stay rejected / checked.**
5. Make the repo `forge fmt`-clean? **Deferred to a dedicated follow-up PR** (format-only; enforce in
   `make check`/CI; metadata-stripped bytecode identity on `src/`). Not mixed into this PR.

## Verdicts (2026-09-27)

| Candidate | Verdict |
|---|---|
| Pack Dex oracle + live floor | **Shipped** in this PR |
| Unchecked lending zero-cash sum | **Shipped** in this PR |
| FeeHandler ownership move | **Follow-up PR** (approved; stack-too-deep to fix there) |
| Gross total into `_batchRetrieveStablecoin` | **Rejected** |
| Swap-pop array bounds assembly | **Open** (sketch for human; not shipping here) |
| Fold `IdleErc20Handler` into `TokenHandler` | **Rejected** |
| Unchecked market / falling-delta / `amountSpent` / lending share sums | **Keep checked** |
| `forge fmt` + CI enforce | **Follow-up PR** |

## Scope

- [x] Reproduce the oracle-packing gas, storage-access, layout, and artifact measurements on R90's real
  base under both profiles before asking for the product verdict.
- [x] Measure the two governance floor setters as storage accesses and convert them to Rootstock.
- [x] Reproduce the lending diagnostic-sum artifact delta under both profiles.
- [x] Prototype moving `FeeHandler` off `TokenHandler` without changing any concrete constructor ABI,
  external selector, event, error, or storage slot. Compare concrete ABI/method identifiers, storage
  layout, metadata-stripped creation/runtime code, deployed size, and representative gas on all live
  idle/Sovryn/LayerBank MoC and Dex leaves.
- [x] Measure how much of `src/`, `test/`, and `script/` `forge fmt` would change, and check whether any
  of it fights the repo's existing layout.
- [x] Present one final evidence table and obtain the human's answers to all open product decisions.
- [x] Implement only the approved subset for this PR (packing + unchecked), one commit per candidate,
  and record deferred/rejected verdicts with their final reason.
- [x] Update `ROOTSTOCK-GAS-AUDIT.md`, this spec's verdict section, `IMPLEMENTATION_ORDER.md`, and
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
