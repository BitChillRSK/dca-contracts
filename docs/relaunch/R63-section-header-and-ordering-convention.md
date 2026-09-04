# R63 — One section-header and function-ordering convention across `src/`

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

Pick one banner vocabulary and one function order, write both into `AGENTS.md`, and apply them to
every file in `src/`. Today the banners use four different names for two concepts and the ordering
rule is followed in most files but not all, so a reader cannot use either as a navigation aid.

## Background

An audit of all 42 `src/` files after R61 found the layout layer is the last part of the codebase
that is still per-file rather than protocol-wide.

**Banner vocabulary is inconsistent.** Two names for the same section in each case:

| concept | spelling A | spelling B |
|---|---|---|
| external entry points | `FUNCTIONS` (`DcaManager`, `PurchaseUniswap`, `IDcaManager`, `IWRBTC`) | `EXTERNAL FUNCTIONS` (`FeeHandler`, `OperationsAdmin`, `TokenHandler`, and every other interface) |
| view accessors | `GETTER FUNCTIONS` (`DcaManager`, `PurchaseUniswap`) | `GETTERS` (`FeeHandler`, `OperationsAdmin`) |

`EXTERNAL FUNCTIONS` and `GETTERS` are each the majority spelling in exactly one of the two groups
(interfaces prefer the first, contracts the second), which is why neither won by drift.

**Coverage is uneven.** `LendingErc20Handler` is 300 lines with a single banner
(`INTERNAL FUNCTIONS` at line 144) and none for its state, constructor, or eleven external
functions. `TokenHandler` has one banner. `PurchaseRbtc` has no getter banner even though
`getAccumulatedRbtcBalance` sits between the externals and the internals. Conversely the small
leaf handlers (`IdleDocHandlerMoc`, the three `*Dex` contracts) have none, which is correct — a
40-line constructor-only contract does not need signposting. The convention has to say where the
floor is, or files keep landing on either side of it.

**Ordering has two real breaks**, both of which mislead:

- `DcaManager._batchBuyRbtc` is `private` and sits at line 295, inside the external `FUNCTIONS`
  block between `batchBuyRbtcAcrossHandlers` and `withdrawRbtcFromTokenHandler`. Every other
  private helper in the file is under `PRIVATE FUNCTIONS` at line 473. A reader scanning the
  external surface has to stop and check the visibility of each entry.
- `LendingErc20Handler` interleaves: `getUserShares` (view, 90) and `supportsInterface` (view, 97)
  sit ahead of `withdrawInterest` (external mutator, 104), so neither "mutators then views" nor
  "grouped by concern" describes the file.

`TokenHandler.supportsInterface` under `EXTERNAL FUNCTIONS` is a third case but arguably fine —
it is `public` because ERC-165 requires the override; call it out in the convention either way so
the next reader does not re-litigate it.

## Open product decisions

**none** — the choices below are editorial and the implementer makes them, but they must be made
once, recorded in `AGENTS.md`, and applied everywhere.

## Scope

- [ ] Choose one banner set and record it in `AGENTS.md` with the exact strings. Suggested, from
      the Solidity style guide order: `TYPE DECLARATIONS`, `STATE VARIABLES`, `EVENTS`, `ERRORS`,
      `MODIFIERS`, `CONSTRUCTOR`, `EXTERNAL FUNCTIONS`, `INTERNAL FUNCTIONS`, `PRIVATE FUNCTIONS`,
      `GETTERS`.
- [ ] Record the size floor: below N declarations a file carries no banners at all.
- [ ] Record the ordering rule: style-guide visibility order (external → public → internal →
      private), and within each group mutators before views.
- [ ] Move `DcaManager._batchBuyRbtc` under `PRIVATE FUNCTIONS`.
- [ ] Regroup `LendingErc20Handler` and give it the full banner set.
- [ ] Apply the chosen vocabulary to every `src/` file that has banners.
- [ ] Add banners to the files above the floor that lack them.

## Out of scope

- [ ] Any change to a function body, signature, visibility, or mutability. This item moves
      declarations and rewrites banner text only.
- [ ] `test/`, `script/`, and the vendored interfaces (`IMocProxy`, `IWRBTC`, `ICoinPairPrice`,
      `IkToken`, `IiSusdToken`, `ILayerBankPool`, `ILayerBankAToken`) — leave vendor files alone so
      they stay diffable against upstream.
- [ ] `forge fmt` on files this item does not otherwise touch.

## Files likely touched

Every `src/**/*.sol` above the size floor. The two ordering fixes are `src/DcaManager.sol` and
`src/LendingErc20Handler.sol`.

## Required tests

- No new tests. This item asserts through the bytecode proof below, not through behavior.
- `make check` (all lanes), `make fork-sovryn`, `make fork-tropykus`, `make check-deploy`.

## Success criteria

- [ ] **Every contract's executable runtime unchanged.** Reordering declarations and editing comments
      must not move a single runtime byte. Compare metadata-stripped `forge inspect <Contract>
      deployedBytecode` before the first edit and at the end, the way R10 does: comments feed the CBOR
      metadata hash, so complete deployed bytecode differs by design and equal `--sizes` output is a
      necessary check rather than a sufficient one. Any delta in the stripped runtime is a bug in the
      change, not an accepted cost.
- [ ] `grep -rn "GETTER FUNCTIONS\|^ *FUNCTIONS$" src/` returns nothing (or the inverse, if the
      other spelling wins).
- [ ] Every `private` and `internal` function in `src/` is below every `external` one in its file.
- [ ] `AGENTS.md` states the convention, so the next file lands correct without a review round.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Metadata-stripped runtime is unchanged everywhere; the before/after table is in the PR. Equal
      `--sizes` output alone does not settle this.
- [ ] No vendored interface was reformatted.
- [ ] No whitespace churn on banners that were already in the chosen form — the diff should show
      renamed banners and moved declarations, nothing else.
- [ ] `AGENTS.md` records the convention including the size floor.

## ABI / deploy / cutover impact

- ABI: none. Declaration order does not affect the ABI, and no selector, event, or indexed field
  moves.
- Scripts: none.
- Cutover: none.
