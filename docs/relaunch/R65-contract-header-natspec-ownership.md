# R65 — Decide which side of an interface/implementation pair owns the header NatSpec

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

Function-level docs already live once, on the interface, and reach the implementation through
`@inheritdoc`. Contract-level docs have no such mechanism, so every interface/implementation pair in
`src/` answers the question by hand and the twelve pairs do not answer it the same way. Pick one rule,
record it in `AGENTS.md`, and apply it.

## Background

Solidity inherits NatSpec for functions, events, errors, and public state variables. It does **not**
inherit the `@title`/`@notice`/`@dev` block that sits above a contract. Measured on the current
`src/`: `LendingErc20Handler`'s devdoc `details` is empty even though `ITokenLending` carries a
paragraph, while its `methods` carry twelve inherited `details` entries. So the choice is real and it
has a consequence — whatever the implementation does not say itself is absent from the artifact that
ships.

The twelve pairs have landed on three different answers:

| answer | pairs |
|---|---|
| paragraph on the implementation only | `PurchaseUniswap`, `IdleErc20Handler`, `LayerBankErc20Handler` |
| paragraph on the interface only | `LendingErc20Handler`, `TokenLending` |
| paragraph on both | `OperationsAdmin` (657 ch on the contract, a 171-ch summary of the same four claims on the interface) |

The remaining pairs carry a `@notice` one-liner on each side and no `@dev` anywhere, which is fine and
should stay: a one-line label naming the artifact is not duplication.

`@inheritdoc` is not an escape hatch here, and the implementer should not spend a build finding that
out: putting `@inheritdoc IDcaManager` on a contract header fails the compile outright with
`Error (6546): Documentation tag @inheritdoc not valid for contracts`. The tag is defined for
functions and public state variables only. Whatever rule this item picks has to be a rule about where
prose is written by hand, because Solidity offers no way to point at it.

`OperationsAdmin` is the case that shows why this needs a rule rather than a preference. Every claim
in `IOperationsAdmin`'s `@dev` — add-only route indexes, add-only handler assignment, at most one
assignment per handler address, no cooperative migration — also appears in `OperationsAdmin`'s, the
second time with the reasons attached. A reader of both reads the rules twice and the reasons once.
Splitting rules-on-the-interface from reasons-on-the-contract is one defensible answer; consolidating
onto one side is another. What is not defensible is deciding it per file.

`@notice` similarity across the pairs runs 0.28 to 0.94, so the near-duplicates
(`FeeHandler`/`IFeeHandler` at 0.94, `OperationsAdmin`/`IOperationsAdmin` at 0.80) should be settled by
the same rule rather than reworded individually.

## Open product decisions

**none** — the choice below is editorial and the implementer makes it, but it must be made once,
recorded in `AGENTS.md`, and applied everywhere.

## Scope

- [ ] Choose the rule and record it in `AGENTS.md`, including the devdoc consequence so the next
      author knows what a missing implementation `@dev` costs. The suggested rule, from what most of
      `src/` already does: the interface owns the consumer-facing paragraph — what the thing is and
      what a caller may rely on — and an implementation carries a `@dev` only for something true of
      the implementation and not of the surface. `@notice` stays on both sides as a label.
- [ ] Apply it to the three pairs that disagree with it, `OperationsAdmin`/`IOperationsAdmin` first.
- [ ] Confirm no pair is left with an exactly duplicated `@dev` or `@notice`.

## Out of scope

- [ ] Function, event, error, and `@param`/`@return` NatSpec. Those already inherit correctly and
      R61 rewrote them; this item is the contract header only.
- [ ] The vendored interfaces (`IMocProxy`, `IWRBTC`, `ICoinPairPrice`, `IkToken`, `IiSusdToken`,
      `ILayerBankPool`, `ILayerBankAToken`) — leave vendor headers alone.
- [ ] Any change to a function body, signature, visibility, or mutability.
- [ ] Banner text and declaration order (R63).

## Files likely touched

`src/OperationsAdmin.sol` and `src/interfaces/IOperationsAdmin.sol` at minimum, plus whichever of the
other eleven pairs the chosen rule moves. `AGENTS.md`.

## Required tests

- No new tests. This item asserts through the bytecode proof below, not through behavior.
- `make check` (all lanes), `make fork-sovryn`, `make fork-tropykus`.

## Success criteria

- [ ] `AGENTS.md` states the rule and the devdoc consequence.
- [ ] No interface/implementation pair in `src/` has an identical `@dev` or `@notice` body.
- [ ] Metadata-stripped runtime unchanged on every contract; comments must not move an executable
      byte. Complete `deployedBytecode` will differ, since the CBOR metadata hash covers comments.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] The rule is stated once in `AGENTS.md` and every file follows it, including the ones that
      already did.
- [ ] Nothing a consumer needs was deleted rather than moved. For each paragraph removed from an
      implementation, the interface says it.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none. NatSpec is not part of the ABI JSON, and no selector, event, indexed field, or
  mutability moves. `devdoc` contract-level `details` moves between artifacts by design.
- Scripts: none.
- Cutover: none. No consumer reads contract-level `devdoc`.
