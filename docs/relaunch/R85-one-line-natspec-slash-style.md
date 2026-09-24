# R85 — NatSpec delimiter: `///` for one line, `/** */` for more

Status: **implemented** · GitHub [#147](https://github.com/BitChillRSK/dca-contracts/pull/147) · Assigned: yes · Optional/further-review: no

## Objective

Record and apply one delimiter rule across first-party `src/`: a NatSpec that is a single tag line
uses `///`, not a three-line `/** … */` block, and NatSpec of two or more lines uses a `/** */` block,
not a run of `///` lines. No behavior, ABI, or storage change.

**Scope widened 2026-09-24 (human decision, during review of #147):** the first push converted only
one-line blocks to `///` and left the existing multi-line `///` runs alone. The human asked for those
runs to become `/** */` blocks in this same PR, so the rule holds in both directions across `src/`.

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
      **Result:** a **NatSpec delimiter** paragraph under **Onchain comments**, stating both directions
      and that `src/` follows it throughout.
- [x] Apply across first-party `src/` and matching `src/interfaces/`: convert every one-line NatSpec
      that is currently a `/**` / `*` / `*/` wrapper into `///`. Leave real multi-line paragraphs alone.
      **Result:** 77 blocks in 12 implementation files (50 `@inheritdoc`, 25 `@dev`, 2 `@param`), each
      3 lines → 1 (+77 / −231). `src/interfaces/` already had none, so no interface file changes.
      Vendored interfaces were excluded from the scan and are untouched. No single-line `/** … */` form
      exists in `src/`, before or after.
- [x] Convert every run of two or more consecutive `///` lines in non-vendored `src/` into a `/** */`
      block at the same indentation, one ` * ` line per `///` line, keeping blank `///` lines as bare
      ` *` and continuation indentation as written (it already matches the existing blocks' `@dev`
      alignment). Added 2026-09-24; see **Objective**.
      **Result:** 47 runs, 134 lines, in 18 files: 7 interfaces with 21 runs (`IDcaManager` 10,
      `ITokenLending` 4, `IFeeHandler` 2, `IPurchaseUniswap` 2, `IIdleErc20Handler`, `IPurchaseRbtc`,
      `ITokenHandler` 1 each) and 11 implementations with 26 runs (`DcaManager` 7, `PurchaseUniswap` 5,
      `LayerBankErc20Handler` 3, `FeeHandler`, `SovrynErc20Handler`, `TropykusErc20Handler` 2 each,
      `DcaManagerAccessControl`, `OperationsAdmin`, `PurchaseMoc`, `PurchaseRbtc`, `TokenHandler` 1
      each). +228 / −134: each run gains an opener and a closer. Every run sits on a declaration (state
      variable, struct, event, error, or function); none is inside a function body. No `///` line sits
      directly next to a `/** */` block, so no NatSpec was split across both styles before or after.
- [x] Do not rewrite wording, retag, or move docs between interface and implementation (R10 / R65).
- [x] Prove metadata-stripped runtime unchanged on every deployable contract.

## Out of scope

- [ ] `test/`, `script/`, `lib/`, and vendored interfaces listed in `AGENTS.md` as leave-alone.
- [ ] Content rewrites, header ownership, section banners (R10 / R65 / R63).
- [ ] Any executable change.

## Files likely touched

- `AGENTS.md`
- First-party `src/**/*.sol` and `src/interfaces/**/*.sol` that still wrap a single NatSpec tag in
  `/** */`, or that carry a multi-line `///` run (start from `DcaManager.sol`; expand only through
  files that match either pattern).

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
- [x] Multi-line NatSpec paragraphs still use `/** */`. The first conversion only matched blocks with
      exactly one body line, so no existing multi-line block was touched.
- [x] No multi-line `///` run remains in non-vendored `src/`. A scan for two or more consecutive `///`
      lines (excluding `////` banner rules) finds 0 (47 before).
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
      bytecode. Separately, the text of each removed body line equals its replacement line, for both
      conversions (77 lines, then 134). Both checks were re-run after the second conversion, against the
      same R84-head build; the byte-identity result above also covers the final tree. Struct docs and
      non-public state-variable docs never reach `devdoc`, so for those the text comparison is the proof.

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
