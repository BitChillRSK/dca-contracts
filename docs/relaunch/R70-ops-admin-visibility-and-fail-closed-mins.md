# R70 — Public OperationsAdmin pin, fail-closed per-token mins, comment accuracy

Status: **implemented** · Assigned: yes · Optional/further-review: no · Order: after R69, before relaunch · Implementation PR: [#127](https://github.com/BitChillRSK/dca-contracts/pull/127)

## Objective

Align `DcaManager`'s OperationsAdmin pin with the public-immutable convention, remove the
cross-decimal default min purchase amount so unset tokens fail closed, and correct one inaccurate
`@dev` on the protected-window helper. Three review follow-ups that should not ship with the
relaunch; no diamond-inheritance or licensing work.

## Background

### 1. Private immutable + named getter is redundant

R46 pinned `OperationsAdmin` as an immutable and kept `getOperationsAdminAddress()` as the
canonical read. R69 then recorded the house rule that construction wiring is
`public immutable` / `public constant`, with `private` + named getters reserved for mutable
storage. `i_operationsAdmin` is still the exception: private with a one-line external wrapper.
Making it `public immutable` and declaring the auto-getter on `IDcaManager` drops the redundant
selector and matches every other pin in `src/`.

### 2. A single default min is unsafe across decimals

`ProtocolSettings.defaultMinPurchaseAmount` is one `uint128` in raw units. Deploy and add-on
scripts historically pass `25 ether` (18 decimals). An unset USDT0 (6 decimals) therefore inherits
`25e18` atomic units — about 25 trillion USDT0 — and the route is unusable until someone remembers
`setTokenMinPurchaseAmount`. Zero in the per-token mapping currently means "use default", so there
is no on-chain way to tell "never configured" from "intentionally defaulted". Explicit per-token
mins are the only sound model: unset reverts, `setTokenMinPurchaseAmount(0)` reverts, and every
listed stable is set at deploy.

`s_tokenMinPurchaseAmounts` stays its own mapping (not folded into `ProtocolSettings`). Removing
`defaultMinPurchaseAmount` frees 16 bytes in that slot; do **not** pad them — leave the remaining
scalars packed and the rest of the word unused.

### 3. `_requireUserMutationsAllowed` NatSpec overclaims

The helper's `@dev` says it exists so the check is not inlined into every guarded entry point.
That is what `whenUserMutationsAllowed` already does. The private is there so the multi-line lock
check (load unlock block, compare `block.number`, revert with that block) stays readable; the
modifier calls it. Do not extract helpers for `onlySwapper` or `validateMinPurchasePeriod`.

## Open product decisions

**none.** Visibility convention and fail-closed mins are engineering; the USDT0 default bug is
already a known ops footgun in the README. Implement without asking.

## Scope

- [x] Change `i_operationsAdmin` to `IOperationsAdmin public immutable override` on `DcaManager`
      (drop the concrete `OperationsAdmin` import). Declare
      `function i_operationsAdmin() external view returns (IOperationsAdmin)` on `IDcaManager`
      (import `IOperationsAdmin`, not the concrete contract). `PurchaseUniswap` reads it through
      `IDcaManager` only.
- [x] Update `PurchaseUniswap`, tests, and any docs that call `getOperationsAdminAddress`.
- [x] Remove `defaultMinPurchaseAmount` from `ProtocolSettings`, the `DcaManager` constructor
      argument, `modifyDefaultMinPurchaseAmount`, `getDefaultMinPurchaseAmount`, and
      `DcaManager__DefaultMinPurchaseAmountModified`.
- [x] In `_validatePurchaseAmount`, if `s_tokenMinPurchaseAmounts[token] == 0`, revert with a new
      clear error (e.g. `DcaManager__TokenMinPurchaseAmountNotSet(address token)`). No default
      fallback.
- [x] `setTokenMinPurchaseAmount`: revert when `minPurchaseAmount == 0` (zero no longer clears an
      override). Update NatSpec on the setter and on `DcaManager__TokenMinPurchaseAmountSet`.
- [x] `getTokenMinPurchaseAmount` returns a single `uint256` (zero means unset). Do not return a
      redundant bool.
- [x] Deploy scripts + harness constructions: after `new DcaManager(...)`, call
      `setTokenMinPurchaseAmount` for every listed stable (DOC / USDRIF `25 ether`, USDT0 `25e6`).
      Do not rely on a constructor default. Set the min **before** `assignTokenHandler` so a token
      is never routable while create still reverts `TokenMinPurchaseAmountNotSet`.
- [x] `DeployMocAndUniswap`: broadcast as `owner` in both branches (same ownership footgun as
      `_beginLiveAwareBroadcast`). Add Anvil coverage that is not excluded from `make check`.
- [x] Update `SchedulePackingTest` (and any other packing assertion) for the new
      `ProtocolSettings` layout: `minPurchasePeriod` | `maxSchedulesPerToken` | `scheduleNonce`, no
      padding for the freed bytes.
- [x] Reword `_requireUserMutationsAllowed`'s `@dev` as in Background §3. Comment only.
- [x] Gas prototypes under `test/gas/prototype/` that mirror `ProtocolSettings` / the constructor
      follow the same shape if they otherwise fail to compile or assert against the real manager;
      do not redesign the R64 benchmark suite.

## Out of scope

- [ ] Diamond-inheritance flattening.
- [ ] Licensing / SPDX.
- [ ] Extracting helpers for `onlySwapper` or `validateMinPurchasePeriod`.
- [ ] Moving `s_tokenMinPurchaseAmounts` into `ProtocolSettings`.
- [ ] Padding the freed bytes in `ProtocolSettings`.
- [ ] `forge fmt` of existing files.
- [ ] Deploy broadcasts.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `src/PurchaseUniswap.sol`
- `script/DeployMocSwaps.s.sol`
- `script/DeployDexSwaps.s.sol`
- `script/DeployMocAndUniswap.s.sol`
- `script/DeployUsdrifHandler.s.sol` (runbook / comments that mention the default)
- `README.md` (USDT0 add-on text that describes the 18-decimal default)
- `test/unit/SchedulePackingTest.t.sol`
- `test/unit/DcaConfigurationTest.t.sol`
- `test/unit/ModifiersTest.t.sol`
- `test/unit/ProtectedPurchaseWindowTest.t.sol`
- `test/unit/deployment/BaseDeploymentTest.t.sol`
- `test/unit/EventIndexingTest.t.sol`
- `test/ai-generated/unit/GettersTest.t.sol`
- `test/ai-generated/unit/HandlerTestHarness.t.sol`
- `test/ai-generated/fuzz/Handler.t.sol`
- Direct `new DcaManager(...)` call sites under `test/` (TwoStepOwnership, edge cases, invariants,
  R64 gas benchmark, …)
- `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

Targeted first:

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract DcaConfigurationTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract SchedulePackingTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract GettersTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract ModifiersTest
STABLECOIN_TYPE=USDT0 LENDING_PROTOCOL=layerbank SWAP_TYPE=dexSwaps forge test --match-path 'test/unit/deployment/**'
```

Behaviors to assert:

- `dcaManager.i_operationsAdmin()` returns the constructor admin; `getOperationsAdminAddress` is gone.
- Creating / updating a purchase amount on a token with no min set reverts
  `DcaManager__TokenMinPurchaseAmountNotSet`.
- `setTokenMinPurchaseAmount(token, 0)` reverts.
- After an explicit min is set, amounts below it still revert
  `DcaManager__PurchaseAmountMustBeGreaterThanMinimum` with that min.
- Deploy paths set DOC/USDRIF to `25 ether` and USDT0 to `25e6`; no constructor default arg remains.
- `ProtocolSettings` still occupies one slot; packing test matches the new field order.
- Sibling purchase / lending paths unchanged beyond the constructor / min wiring.

Fork tests: no new fork-specific assertions. Still run `make fork-sovryn` and `make fork-tropykus`
before push.

Done-gate: `make check`, then the forks above.

## Success criteria

- [x] `i_operationsAdmin` is `IOperationsAdmin public immutable override`; `getOperationsAdminAddress`
      is gone; `IDcaManager` declares the getter returning `IOperationsAdmin` (not the concrete type).
- [x] No `defaultMinPurchaseAmount` / `modifyDefaultMinPurchaseAmount` /
      `getDefaultMinPurchaseAmount` / `DcaManager__DefaultMinPurchaseAmountModified` remain.
- [x] `getTokenMinPurchaseAmount` returns a single `uint256` (zero = unset / not listed).
- [x] Unset token min reverts on purchase-amount validation; setter rejects zero.
- [x] Every production deploy / add-on path that lists a stable sets its min explicitly, before
      handler assignment.
- [x] `_requireUserMutationsAllowed` `@dev` matches Background §3.
- [x] `make check`, `make fork-sovryn`, and `make fork-tropykus` green.
- [x] Consumer issues opened/updated for the ABI breaks; URLs in the PR cutover note.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable (prefer one commit per follow-up).
- [ ] `ProtocolSettings` was not padded after dropping the default.

## ABI / deploy / cutover impact

- ABI:
  - Remove `getOperationsAdminAddress()`. Replacement getter is literally named
    `i_operationsAdmin()` and returns `IOperationsAdmin` (declared on `IDcaManager`).
  - `PROTECTED_PURCHASE_WINDOW_BLOCKS` is a new `public constant` (new selector; monitoring
    regenerates `abi.json`).
  - Remove constructor arg `defaultMinPurchaseAmount`.
  - Remove `modifyDefaultMinPurchaseAmount`, `getDefaultMinPurchaseAmount`, and
    `DcaManager__DefaultMinPurchaseAmountModified`.
  - `setTokenMinPurchaseAmount(0)` now reverts (was: clear override).
  - New error `DcaManager__TokenMinPurchaseAmountNotSet(address token)`.
  - `getTokenMinPurchaseAmount` returns a single `uint256` (zero = unset / not listed for create).
- Scripts: every `new DcaManager` call site; explicit `setTokenMinPurchaseAmount` for listed
  stables in MoC and Dex deploys; USDT0 add-on runbook no longer describes an 18-decimal default.
- Cutover: front-end / data-api / monitoring / swapper-bot if any still call the removed selectors
  or assume a protocol-wide default min. Open or update consumer issues per `AGENTS.md`.
