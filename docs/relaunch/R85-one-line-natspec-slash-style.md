# R85 — one-line NatSpec uses `///`

Status: **implemented** · GitHub [#147](https://github.com/BitChillRSK/dca-contracts/pull/147) · Assigned: yes · Optional/further-review: no

## Objective

Record and apply one delimiter rule across first-party `src/`: a NatSpec that is a single tag line
uses `///`, not a three-line `/** … */` block. Multi-paragraph docs stay in `/** */` blocks. No
behavior, ABI, or storage change.

## Background

Raised while reviewing R81. `/// @inheritdoc IDcaManager` is clearer than:

```solidity
/**
 * @inheritdoc IDcaManager
 */
```

Solidity accepts both. This repo already mixes them (~240 `/// @` lines and ~235 multi-line `/**`
blocks in `src/`). Neither `AGENTS.md` nor R10 picks a delimiter. OpenZeppelin mostly uses blocks;
that is not a reason to keep three-line wrappers for a single tag here.

R10 owns content (interface-owned docs, `@inheritdoc`, no stubs). R65 owns contract-header ownership.
This item is only the delimiter for one-line tags. Comment-only: metadata-stripped runtime must stay
byte-identical on every deployable contract (same proof shape as R63 / R65).

## Open product decisions

**none**

## Scope

- [x] Add the rule to `AGENTS.md` under the NatSpec / onchain-comments area (next to R10/R65 guidance):
      one tag line → `///`; two or more lines of NatSpec body → `/** */`.
      **Result:** a **NatSpec delimiter** paragraph under **Onchain comments**. It also says that the
      short multi-line `///` runs already in `src/` stay as they are — see
      [Existing `///` runs](#existing--runs).
- [x] Apply across first-party `src/` and matching `src/interfaces/`: convert every one-line NatSpec
      that is currently a `/**` / `*` / `*/` wrapper into `///`. Leave real multi-line paragraphs alone.
      **Result:** 77 blocks in 12 implementation files (50 `@inheritdoc`, 25 `@dev`, 2 `@param`), each
      3 lines → 1 (+77 / −231). `src/interfaces/` already had none, so no interface file changes.
      Vendored interfaces were excluded from the scan and are untouched. No single-line `/** … */` form
      exists in `src/`, before or after.
- [x] Do not rewrite wording, retag, or move docs between interface and implementation (R10 / R65).
- [x] Prove metadata-stripped runtime unchanged on every deployable contract.

## Out of scope

- [ ] `test/`, `script/`, `lib/`, and vendored interfaces listed in `AGENTS.md` as leave-alone.
- [ ] Content rewrites, header ownership, section banners (R10 / R65 / R63).
- [ ] Any executable change.
- [ ] Rewriting the existing multi-line `///` runs as `/** */` blocks (see below).

### Existing `///` runs

The scope's rule has a second half — two or more lines of NatSpec body use `/** */` — and `src/`
already breaks it in 49 places: consecutive `///` lines on state variables, errors, and
events, usually a `@notice` / `@dev` pair or one sentence wrapped at the line limit (for example
`DcaManager`'s storage declarations, `PurchaseUniswap`'s immutables, `IFeeHandler`'s struct and event).
The scope names only the opposite conversion, and "leave real multi-line paragraphs alone" reads as
covering these too, so they stay. Rewriting them would be a second, larger churn of the same kind for
no reader benefit, since a two-line `///` run is not hard to read. The `AGENTS.md` rule says so
explicitly rather than stating a rule the tree does not follow, and asks new multi-line NatSpec to be
written as a block.

## Files likely touched

- `AGENTS.md`
- First-party `src/**/*.sol` and `src/interfaces/**/*.sol` that still wrap a single NatSpec tag in
  `/** */` (start from `DcaManager.sol`; expand only through files that match the pattern).

## Required tests

- `make check` (comment-only; lanes stay green).
- Metadata-stripped runtime compare for every deployable contract vs the parent commit (R10/R63/R65
  method). Complete `deployedBytecode` may differ (CBOR metadata hash includes comments).
- No new behavior tests. Fork lanes still run before push per `AGENTS.md`; no fork-specific asserts.

**Results:** `make check` green: nine lanes, 0 failures. `make fork-sovryn` passed 450, skipped 30, failed 0.
`make fork-tropykus` passed 443, skipped 34, failed 0. The runtime comparison is recorded under
**Success criteria**.

## Success criteria

- [x] `AGENTS.md` states the delimiter rule.
- [x] No first-party `src/` one-line NatSpec remains wrapped in a three-line `/** */` block. A scan for
      a `/**` line, one non-empty `*` line, and a `*/` line over every non-vendored `src/` file finds 0
      (77 before).
- [x] Multi-line NatSpec paragraphs still use `/** */`. The conversion only matched blocks with exactly
      one body line; no block with two or more lines was touched.
- [x] Metadata-stripped runtime byte-identical on all deployable contracts.
      **Result:** built `src/` at the parent commit (`5d3b567`, R84 head) and at this branch, under both
      the default profile and `deploy` (`via_ir`, what ships). For all ten deployable contracts
      (`DcaManager`, `OperationsAdmin`, and the eight `*DocHandlerMoc` / `*Erc20HandlerDex` leaves,
      Tropykus included), both runtime and creation code are byte-identical once the trailing CBOR
      metadata is stripped, on both profiles. The full `deployedBytecode` differs on every one of them,
      so the comparison did see the change: the metadata hash covers comments, and nothing else moved.
- [x] No ABI, event, storage, or wording change beyond the delimiter. The compiler's own `devdoc`,
      `userdoc`, and `abi` outputs are identical on every artifact in the `src/` build (114 artifacts,
      both profiles), which is the compiler confirming the NatSpec content is unchanged, not only the
      bytecode. Separately, the text of each removed body line equals its replacement `///` line.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none. NatSpec is not part of the ABI JSON.
- Scripts: none.
- Cutover: none. `AGENTS.md` lists NatSpec under “do not open an issue for.”
