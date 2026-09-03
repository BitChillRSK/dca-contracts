# R61 — clean the `src/` comment layer and close two ABI/layering defects

Status: **assigned** · Assigned: yes · Optional/further-review: no

## Objective

Bring the `src/` comment layer back to a single authored voice and fix the small correctness defects a
comment audit surfaced. Verified `src/` source lives on explorers for the life of the deployment, so
review-round accretion, dead vendor surface, and a getter whose interface disagrees with its
implementation are all durable costs. No runtime behavior changes.

## Background

An audit of all 42 `src/` files after the R60 stack found that comment *volume* is not the problem:
across the whole relaunch `src/` went 3,902 → 4,552 lines (+278 code, +372 comment), moving the
comment:code ratio 0.71 → 0.78. That density is in line with comparable protocols and is not the
finding.

What the audit did find is a set of patterns that read as accretion rather than authorship, plus four
real defects:

1. **`IFeeHandler.getFeeCollectorAddress()` is missing `view`.** The implementation is `view`; Solidity
   permits an override to narrow mutability, so it compiles, but the *published ABI* says nonpayable.
   Generated clients (wagmi/ethers) build a transaction for a getter. Every sibling getter on that
   interface is correctly `view`.
2. **The `DcaSchedule` packing NatSpec describes a build that is no longer shipped.** It reads "Without
   IR, those updates remain two `SSTORE`s"; R60 added `[profile.deploy] via_ir = true`, so the shipped
   bytecode *is* IR-compiled. The note is scoped to the profile that does not deploy.
3. **`IStablecoin` is test-only but lives in `src/interfaces/`.** Zero references in `src/` or
   `script/`; only `test/mocks/*`. Its own NatSpec says "Not a production token ABI."
   `test/interfaces/IStablecoinHandler.sol` is the established home for this.
4. **`deleteDcaSchedule` is the only schedule mutator whose `nonReentrant` is not first**, with trailing
   whitespace on the same lines. `AGENTS.md` invariant 6 is explicitly "checkable with grep"; this is the
   one line that reads differently under that grep.

The comment-layer patterns, all of which write internal process into permanent on-chain source:

- **Stacked `@dev` blocks.** Four consecutive `@dev` tags means four review rounds each appended a
  defense instead of editing the existing paragraph. `topUpFromInterest` carries 4 in `DcaManager` plus a
  24-line block in `IDcaManager` — 42 lines of prose across two files for a 33-line function, which
  explains the ceiling-vs-quote distinction twice.
- **NatSpec tags inside function bodies** (11 sites). `// @notice foo` on a line inside a function is not
  NatSpec; it renders nowhere. Two use `// @notice:` with a colon, which no tag takes.
- **Verbatim duplication** between a NatSpec line and an inline comment two lines below it.
- **Gas lore.** Precise figures ("worth ~74 gas per row") and editorializing ("buys nothing", "the
  expensive way") carved into immutable source. The figures were measured under `via_ir = false`, which
  R60 made the non-shipping profile.
- **Internal vocabulary leaking to the explorer.** `AGENTS.md` bans R-ids in `src/` comments; these are
  the same class and escaped the `R\d+` grep: "invariant 1 is handler cash" (that list lives in
  `AGENTS.md`, not on Etherscan), "Individual bound/rate setters were removed" (a diff, not a contract),
  "the max-schedules bound has sat here since the count check was fixed" (repo history).

Dead interface surface: `ICoinPairPrice` is 157 lines of which 22 of 25 members are called nowhere in
`src/`, `script/`, or `test/` — BitChill calls `getPriceInfo()`. It also carries a
`CoinPairPriceCallbacks` struct of function-pointer types nothing touches and four commented-out vendor
declarations. `IWRBTC` is 9-of-11 unused but is the canonical WETH ABI, which is a weaker case.

## Open product decisions

**none** — every item is a comment, a layering move, or a mutability annotation. Nothing changes runtime
behavior, storage layout, or an event.

## Scope

- [ ] Add `view` to `IFeeHandler.getFeeCollectorAddress()` so the published ABI matches the implementation.
- [ ] Rewrite the `DcaSchedule` packing `@dev` so it states the durable slot layout without pinning a
      claim to a non-shipping codegen profile.
- [ ] Move `IStablecoin` from `src/interfaces/` to `test/interfaces/` and update the four mock imports.
- [ ] Put `nonReentrant` first on `deleteDcaSchedule` and strip the three trailing-whitespace lines in
      `src/`.
- [ ] Collapse stacked `@dev` blocks into one authored paragraph per function, at minimum:
      `DcaManager.topUpFromInterest` (4), `IDcaManager.topUpFromInterest` (24 lines),
      `PurchaseUniswap._getAmountOutLowerBound` (3), `PurchaseUniswap` constructor (20 lines),
      `PurchaseUniswap._purchaseRbtc` (2), `ITokenLending`, `IPurchaseUniswap`, `IPurchaseRbtc`,
      `OperationsAdmin`.
- [ ] Convert the 11 in-body `@notice`/`@dev` tags to plain comments, or hoist the content into the
      function's real NatSpec where it belongs there.
- [ ] Delete inline comments that restate the NatSpec directly above them.
- [ ] Remove gas figures and editorializing from `src/` comments, keeping the durable reason.
- [ ] Replace leaked internal vocabulary ("invariant 1", "were removed", "since the count check was
      fixed") with the standalone reason.
- [ ] Trim `ICoinPairPrice` to the members BitChill and its tests actually call, keeping the vendor
      attribution header.
- [ ] Nits: `custody` grammar in `IDcaManager`; `poping` typo in `DcaManager`; clarify that
      `DcaSchedule.paused` is set by the schedule's user, not the protocol owner; give `HUNDRED_PERCENT`
      and `FEE_PERCENTAGE_DIVISOR` explicit visibility; unify the three section-banner styles.

## Out of scope

- [ ] Any runtime behavior, storage layout, event, or error-signature change.
- [ ] Trimming `IWRBTC` (canonical WETH ABI; churn against upstream for little gain).
- [ ] Removing `TokenLending__LendingProtocolRedeemFailed` — declared on the shared `ITokenLending` and
      raised only by legacy Tropykus. Deleting it is an ABI change on a shared interface for a dead
      code path; not worth it here.
- [ ] `forge fmt` over `src/` (`AGENTS.md`: `src/` is not fmt-clean; do not reformat wholesale).
- [ ] Wrapping the 24 lines over 120 chars, except where a rewritten comment naturally shortens them.
- [ ] The licensing / SPDX question (human decision, tracked in `IMPLEMENTATION_ORDER.md`).

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol`
- `src/PurchaseRbtc.sol`, `src/interfaces/IPurchaseRbtc.sol`
- `src/FeeHandler.sol`, `src/interfaces/IFeeHandler.sol`
- `src/LendingErc20Handler.sol`, `src/interfaces/ITokenLending.sol`, `src/interfaces/ITokenHandler.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/ICoinPairPrice.sol`
- `src/interfaces/IStablecoin.sol` → `test/interfaces/IStablecoin.sol` (+ four `test/mocks/*` imports)

## Required tests

No new tests: this PR changes no behavior, so the existing suite is the regression gate. What must pass
is that the suite is unchanged *and* still green.

- Full done-gate `make check` (`forge build`, `make moc-none`, `make moc-layerbank`, `make moc-sovryn`,
  `STABLECOIN_TYPE=USDRIF make dex-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-layerbank`,
  `STABLECOIN_TYPE=USDT0 make dex-layerbank`, `make invariants-sovryn`).
- `make fork-sovryn` and `make fork-tropykus` before push (`AGENTS.md`).
- `forge build --sizes` before and after. Every contract except `DcaManager` must be **byte-identical**;
  comments and a `view` annotation must not move bytecode. `DcaManager` moves by exactly the
  `deleteDcaSchedule` modifier reorder, which must be isolated by rebuilding with that one change
  reverted and confirming the baseline size returns.
- `forge inspect FeeHandler abi` must show `getFeeCollectorAddress` as `view` after the change.

## Success criteria

- [ ] `make check` green; `make fork-sovryn` and `make fork-tropykus` green.
- [ ] `forge build --sizes` byte-identical for every contract except `DcaManager`, whose delta is
      measured and shown to come only from the modifier reorder.
- [ ] No `@notice` / `@dev` / `@param` / `@return` tag remains inside a function body in `src/`.
- [ ] No `src/` comment contains a gas figure, an R-id, an `AGENTS.md` invariant number, or a sentence
      about what a previous PR changed.
- [ ] No function in `src/` carries more than one `@dev` block.
- [ ] `grep -rn " $" src/` returns nothing.
- [ ] `IStablecoin` has no reference from `src/` or `script/`.
- [ ] `getFeeCollectorAddress` is `view` in interface and implementation.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold — none is touched; invariant 6's grep is *easier* to
      run after the `deleteDcaSchedule` modifier reorder.
- [ ] Sizes byte-identical apart from `DcaManager`'s isolated modifier-reorder delta; the diff is
      comments, one `view`, one file move, one modifier reorder, one interface trim.
- [ ] Every surviving comment says something the code does not, and says it once.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- **ABI:** `IFeeHandler.getFeeCollectorAddress` becomes `view` (nonpayable → view). The deployed function
  already behaved this way; this only corrects what the ABI advertises. A consumer that generated a
  write binding for it should regenerate. No selector changes, no event or error changes.
- **Scripts:** none.
- **Cutover:** the frontend should regenerate the `FeeHandler` ABI so `getFeeCollectorAddress` is called
  rather than sent. Low urgency — a call against the old binding still works, it just costs a
  transaction round-trip in tooling that honors the mutability flag.
