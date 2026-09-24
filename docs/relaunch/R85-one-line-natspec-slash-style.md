# R85 — one-line NatSpec uses `///`

Status: **not started** · Assigned: no · Optional/further-review: no

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

- [ ] Add the rule to `AGENTS.md` under the NatSpec / onchain-comments area (next to R10/R65 guidance):
      one tag line → `///`; two or more lines of NatSpec body → `/** */`.
- [ ] Apply across first-party `src/` and matching `src/interfaces/`: convert every one-line NatSpec
      that is currently a `/**` / `*` / `*/` wrapper into `///`. Leave real multi-line paragraphs alone.
- [ ] Do not rewrite wording, retag, or move docs between interface and implementation (R10 / R65).
- [ ] Prove metadata-stripped runtime unchanged on every deployable contract.

## Out of scope

- [ ] `test/`, `script/`, `lib/`, and vendored interfaces listed in `AGENTS.md` as leave-alone.
- [ ] Content rewrites, header ownership, section banners (R10 / R65 / R63).
- [ ] Any executable change.

## Files likely touched

- `AGENTS.md`
- First-party `src/**/*.sol` and `src/interfaces/**/*.sol` that still wrap a single NatSpec tag in
  `/** */` (start from `DcaManager.sol`; expand only through files that match the pattern).

## Required tests

- `make check` (comment-only; lanes stay green).
- Metadata-stripped runtime compare for every deployable contract vs the parent commit (R10/R63/R65
  method). Complete `deployedBytecode` may differ (CBOR metadata hash includes comments).
- No new behavior tests. Fork lanes still run before push per `AGENTS.md`; no fork-specific asserts.

## Success criteria

- [ ] `AGENTS.md` states the delimiter rule.
- [ ] No first-party `src/` one-line NatSpec remains wrapped in a three-line `/** */` block.
- [ ] Multi-line NatSpec paragraphs still use `/** */`.
- [ ] Metadata-stripped runtime byte-identical on all deployable contracts.
- [ ] No ABI, event, storage, or wording change beyond the delimiter.

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
