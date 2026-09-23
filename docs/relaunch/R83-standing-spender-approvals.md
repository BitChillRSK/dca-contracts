# R83 — standing vs per-use spender approvals

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

Decide whether the two sites that approve an exact amount before every spend should hold a standing
approval instead, and implement that decision:

- `PurchaseUniswap._purchaseRbtc` approves `SwapRouter02` on every Dex batch (protocol-paid).
- `LendingErc20Handler._depositToken` approves the lending spender on every lending deposit and create
  (user-paid).

On Rootstock the 0 → amount → 0 allowance round trip costs about 10,000 net storage gas per use.
Ethereum's same-transaction refund makes it nearly free there, which is why it never registered.

## Background

Found by the [Rootstock gas audit of `src/`](./ROOTSTOCK-GAS-AUDIT.md).

Both sites leave the spender's allowance at 0 after the spend, because the spender pulls exactly the
approved amount. The next use therefore starts again from 0:

- **Ethereum/Cancun:** `SET` on a cold slot, then a return to the original 0 in the same transaction,
  refunds 19,900 under EIP-2200/3529. Net cost is about 2,300.
- **Rootstock:** `SET` 20,000 + `CLEAR` 5,000 − `REFUND` 15,000 = **10,000** net, plus the approve call
  itself (`CALL` is a flat 700 on Rootstock). See [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md).

Measured with the audit harness (deploy profile) against an OZ 5 `ERC20`, which skips the allowance
decrement for `type(uint256).max`:

| Pattern | Cancun exec (pre-refund) | RSK storage net of refund |
|---|---:|---:|
| `forceApprove(spender, amount)` then spender `transferFrom(amount)` | 33,373 | 21,400 |
| standing `max` approval, spender `transferFrom(amount)` | 10,214 | 11,000 |

The saving per use is therefore about **10,400 Rootstock storage gas plus one external call**. It is
smaller (about 5,400) if a stablecoin decrements even a `max` allowance, because each spend is then a
`RESET` rather than no write. Which of DOC, USDRIF, and USDT0 skip the decrement is a fork fact this
PR must establish.

MoC purchase routes are not affected: `redeemFreeDoc` burns DOC from the caller without an allowance.

## Open product decisions

Ask the human, stating the measured saving and the exposure for each site:

1. **Uniswap router (protocol-paid, every Dex batch).** Should Dex handlers hold a standing
   stablecoin approval to the immutable `i_swapRouter02`? The exposure is every stablecoin balance the
   handler holds between calls. For `IdleErc20HandlerDex` that is **every idle user's deposit**. For a
   lending Dex handler it is only the transient batch amount. Options: keep exact approvals; standing
   approval on lending Dex handlers only; standing approval on all Dex handlers.
2. **Lending spender (user-paid, every lending deposit).** Should lending handlers approve their
   spender (Sovryn iSUSD, LayerBank pool) once, in the constructor? The spender already custodies
   every deposited stablecoin as the lending position, so the extra exposure is only the stablecoin
   briefly held during a deposit or redeem. The implementer records each spender's admin/upgrade model
   in the PR so the human answers with it in hand.

If both answers are "keep exact approvals", this item closes with no code change and the reason is
recorded in `IMPLEMENTATION_ORDER.md`.

## Scope

- [ ] Fork-measure whether DOC, USDRIF, and USDT0 decrement a `type(uint256).max` allowance on
      `transferFrom` (read the allowance before and after a spend) and record the result in the PR.
- [ ] Implement the answered option(s) only:
  - Lending: approve `type(uint256).max` to `_lendingSpender()` once, at construction. Keep the
    existing `allowance < depositAmount` top-up as the fallback for a token that decrements.
  - Dex: approve the router once at construction for the handler classes the human chose, and drop the
    per-batch `forceApprove` there. Leave invariant 12's exact-consumption check exactly as it is.
- [ ] State in each affected contract's header `@dev` that the handler holds a standing approval to
      that spender (`AGENTS.md` **Say what is enforced, and what is only assumed**).
- [ ] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Approval changes for any other spender or token.
- [ ] Any change to invariant 11 or 12 measurement.
- [ ] Revoking or rotating standing approvals (no new admin surface unless the human asks for it).

## Files likely touched

- `src/PurchaseUniswap.sol`
- `src/LendingErc20Handler.sol`
- the Dex / lending leaf headers that gain the standing-approval `@dev` line
- matching unit and fork tests

## Required tests

- Unit: after construction the chosen spender's allowance is `max`. A deposit or batch with the
  standing approval succeeds and leaves invariant 12's delta check green. The fallback top-up still
  works when a mock token decrements `max`.
- Fork: the allowance-decrement facts for DOC, USDRIF, and USDT0 (Anvil can read them; it does not
  price them).
- A Foundry gas figure per site, labelled Foundry, plus the Rootstock storage derivation from
  `ROOTSTOCK-GAS-SCHEDULE.md`.
- `make check`, `make check-deploy`, `make fork-sovryn`, `make fork-tropykus`, `make fork-dex-path`.

## Success criteria

- [ ] Both product questions are answered and recorded.
- [ ] Only the answered sites change; the saving is stated on both schedules.
- [ ] Headers state the standing approval where one now exists.

## Reviewer checklist

- [ ] Matches **Scope** and the recorded answers; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (1, 11, 12 in particular).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none, unless a constructor argument is added (it should not be).
- Cutover: none for consumers. The standing approvals are part of the audited deploy state.
