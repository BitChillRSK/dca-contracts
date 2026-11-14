# R65 — Decide which side of an interface/implementation pair owns the header NatSpec

Status: **implemented** · Assigned: yes · Optional/further-review: no

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

## Decision (revised under review)

The first implementation of this item chose "the interface owns the paragraph" and accepted, as the
measured price of the rule, that `OperationsAdmin` would ship an empty contract-level `details`. Review
rejected that trade and it was right to. The priority was backwards: it let *no duplicated `@dev`*
outrank *a deployed contract is readable on its own*. Anyone auditing this protocol lands on the
verified concrete contract, and concise overlap between an implementation and its interface is
deliberate redundancy on the artifact that ships, not duplication to be factored out.

One part of the original reasoning survives and one does not. The devdoc measurement stands: header
NatSpec does not travel down an inheritance chain, so an **abstract** contract's paragraph reaches no
shipped artifact whichever side it sits on, and single-sourcing those on the interface costs nothing.
What does not survive is extending that to deployed contracts, where the field is exactly what is lost.
The rule now splits on that line rather than applying uniformly.

**The revised rule**, in `AGENTS.md`:

- **Every deployed contract carries a short `@dev` on its own security and lifecycle model** — what is
  irreversible, what is guarded, what can be paused, who may call — written even when the interface says
  the same thing. Applying this surfaced three contracts the original pass never considered: the
  `*DocHandlerMoc` leaves shipped no `details` at all, before or after R65.
- Abstracts stay single-sourced on the interface, for the reason above.
- The interface still owns the full paragraph: the caller-facing rules **and** the reasoning behind them.
- The two no-interface-owns-it cases stand unchanged (zero-function interfaces; a fact true of one
  implementation among several sharing `ITokenLending`).

Two further defects came out of the same review, neither of them about placement:

**Comments naming tokens in token-agnostic contracts.** `PurchaseUniswap` is constructed with whatever
stablecoin it is given and rejects only >18 decimals; naming DOC on it is not merely stale but *wrong*,
since DOC is redeemed at Money on Chain and never swapped on Uniswap — R62's own `IdleErc20HandlerDex`
header says exactly that. The USDRIF/USDT0 roster beside it is a listing snapshot that rots. Three sites
fixed (`IPurchaseUniswap` header, `PurchaseUniswap`'s scale comment, `IdleErc20Handler._retrieveStablecoin`)
and the prohibition generalized in `AGENTS.md` so the next one does not land. `IDcaManager`'s mention of
DOC is **kept**: it describes the MoC venue specifically, where the claim is true.

**Documented policy the contract does not enforce.** The peg paragraph asserted a listing rule and a
delisting process, neither of which exists in code, which reads as a safety mechanism. It now separates
what the constructor checks (the decimal bound, the scaling) from what is assumed of governance (the
peg), and says recovery from a persistent depeg is a governance action.

## Superseded first decision

**The interface owns the paragraph.** Recorded in `AGENTS.md` under **Contract header NatSpec**:

- Every first-party `src/` file carries `@title`, `@author`, and exactly one `@notice` line.
- The two `@notice` lines of a pair are labels and must not be the same sentence. The interface's names
  the surface; the implementation's names what that contract is in the system.
- The `@dev` paragraph — what a caller may rely on, and why — belongs to the interface that declares the
  functions it describes. An implementation adds a `@dev` only for a fact about its own code that a
  reader of the surface could not infer, and never restates a claim the interface makes.
- Two exceptions, both because no interface owns the claim: an interface declaring **no functions**
  (`IDcaManagerAccessControl`, `IPurchaseMoc`, `ILayerBankErc20Handler`) is a home for errors and events,
  not a surface, so the paragraph stays on the implementation; and a fact true of one implementation
  cannot live on an interface several share (`ITokenLending` is Sovryn's, LayerBank's, and Tropykus's),
  so it stays on that implementation.

Two facts moved the choice past preference, and neither was in the spec as written.

**The zero-function interfaces.** Three of the twelve first-party interfaces declare no function at all
— `IDcaManagerAccessControl` (1 error), `IPurchaseMoc` (2 errors), `ILayerBankErc20Handler` (2
constructor errors). They are homes for declarations, not surfaces, and a mechanical "interface side"
rule would have filed `LayerBankErc20Handler`'s aToken-scaling paragraph in a file whose entire content
is two constructor errors. The `LayerBankErc20Handler`/`ILayerBankErc20Handler` pair is therefore
*compliant as it stands* — it is not one of the three the spec expected to move. The criterion is one
grep (`grep -c '^\s*function ' <interface>`), not a judgement call.

**The devdoc consequence is narrower than the spec's framing.** Contract-level NatSpec is own-file: it
does not travel down an inheritance chain either, so `SovrynDocHandlerMoc`'s `details` is empty today
regardless of what `SovrynErc20Handler` or `LendingErc20Handler` say. An abstract contract's paragraph
therefore reaches no shipped artifact at all, which removes the "whatever the implementation does not
say is absent from the artifact that ships" objection from every pair except the two non-leaf
deployables. Measured across the ten deployable contracts, the whole price of this rule is one entry:

| contract | contract-level `details` | per-method `details` |
|---|---|---|
| `OperationsAdmin` | present → **moved to `IOperationsAdmin`'s artifact** | 16 → 16 |
| `SovrynErc20HandlerDex` | absent → present (leaf normalisation below) | 30 → 30 |
| `TropykusErc20HandlerDex` | absent → present (leaf normalisation below) | 30 → 30 |
| the other seven | unchanged | unchanged |

`DcaManager` keeps its own `details`, because its paragraph is about storage and modifier discipline and
was never a restatement of the surface. Per-method `details` is unaffected everywhere, since functions do
inherit.

## What changed

| pair | before | after |
|---|---|---|
| `OperationsAdmin`/`IOperationsAdmin` | `@dev` on both, impl a 657-char superset | rules **and** their reasons consolidated on the interface (685 ch); impl keeps a label |
| `PurchaseUniswap`/`IPurchaseUniswap` | `@dev` on impl only | the $1-peg min-out paragraph moves to the interface it constrains |
| `IdleErc20Handler`/`IIdleErc20Handler` | `@dev` on impl only | the clamp rule moves to the interface; "pooled DOC" corrected to "pooled stablecoin" (idle serves USDRIF and USDT0 since R62) |
| `DcaManager`/`IDcaManager` | first `@notice` sentence byte-identical | impl `@notice` names the ledger; the second `@notice` ("maximum frequency is daily") drops, already stated three times in `IDcaManager` |
| `FeeHandler`/`IFeeHandler` | `@notice` 0.94 similar | interface names the configuration, impl names the math |
| `DcaManagerAccessControl`/`IDcaManagerAccessControl` | `@notice` 0.77 similar | interface says what it carries (the revert), per the zero-function exception |
| `LayerBankErc20Handler`, `LendingErc20Handler`, `TokenLending`, and the four unchanged pairs | — | already compliant |

Maximum `@notice` similarity across the twelve pairs falls **0.94 → 0.63**, and every pair now carries its
`@dev` on exactly one side. `DcaManager`/`IDcaManager` is the one pair with a `@dev` on both, which is the
rule working rather than an exception to it: the two say different things (similarity 0.02).

## Files beyond the pair list

The four `*Erc20HandlerDex` leaves stated one shared constructor fact in three different tags —
`IdleErc20HandlerDex` and `LayerBankErc20HandlerDex` in `@dev` with a "same shape as X" cross-reference
that chained rather than described, `SovrynErc20HandlerDex` in `@notice`, `TropykusErc20HandlerDex`
nowhere. All four now say `Constructor-only leaf.` plus the funding-base-first ordering in `@dev`, and the
cross-references are gone, so the four headers diff cleanly against each other. These are deployed
contracts, so this is the two `details` entries gained in the table above. `SovrynErc20HandlerDex`'s
`@notice` also drops a deployment-count claim rather than gaining one: `DeployDexSwaps` builds a single
Sovryn Dex handler for the configured `STABLECOIN_TYPE`, and the USDRIF/USDT0 add-on
(`DeployUsdrifHandler`) is LayerBank-only.

## Open product decisions

**none** — the choice below is editorial and the implementer makes it, but it must be made once,
recorded in `AGENTS.md`, and applied everywhere.

## Scope

- [x] Choose the rule and record it in `AGENTS.md`, including the devdoc consequence so the next
      author knows what a missing implementation `@dev` costs. The suggested rule, from what most of
      `src/` already does: the interface owns the consumer-facing paragraph — what the thing is and
      what a caller may rely on — and an implementation carries a `@dev` only for something true of
      the implementation and not of the surface. `@notice` stays on both sides as a label.
- [x] Apply it to the pairs that disagree with it, `OperationsAdmin`/`IOperationsAdmin` first.
- [x] Confirm no pair is left with an exactly duplicated `@dev` or `@notice`.

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

- [x] `AGENTS.md` states the rule and the devdoc consequence. The consequence is now stated as the
      reason abstracts are single-sourced and deployed contracts are not, rather than as a price paid.
      All ten deployable contracts ship a non-empty contract-level `details`; three of them did not
      before this item.
- [x] No interface/implementation pair in `src/` has an identical `@dev` or `@notice` body. Maximum
      `@notice` similarity 0.63. Note this criterion is now read as the spec wrote it — *identical* —
      rather than as "minimise overlap": under the revised rule a deployed contract's `@dev`
      deliberately restates its interface's claims in short form, which the original pass treated as
      a defect to be eliminated.
- [x] Metadata-stripped runtime unchanged on every contract; comments must not move an executable
      byte. Complete `deployedBytecode` will differ, since the CBOR metadata hash covers comments.
      **Result:** metadata-stripped runtime byte-identical on all ten deployable contracts (SHA-256 of
      the stripped runtime compared against a build of this branch's base). `deployedBytecode` differs
      on all ten in the trailing metadata hash and nowhere else, so the total length does not move
      either and `forge build --sizes` shows no change — which is exactly why the comparison is the
      metadata-stripped one R10 established rather than the size table.

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
