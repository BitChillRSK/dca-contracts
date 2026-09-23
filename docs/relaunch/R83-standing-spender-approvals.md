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

Those savings are steady-state. A standing approval also costs one zero → `max` allowance write when it
is set: a `SET` of about 20,000 Rootstock gas plus the approve call. It is paid once, by the deployer,
at construction. The break-even is therefore:

- about **2 uses** for a token that preserves a `max` allowance;
- about **4 uses** for a token that decrements it.

A Dex handler passes that within its first few batches, and a lending handler within its first few
deposits. For lending, the standing approval also moves the per-deposit cost off users and onto the
one-time deploy.

MoC purchase routes are not affected: `redeemFreeDoc` burns DOC from the caller without an allowance.

## Open product decisions

Ask the human, stating for each site the steady-state saving, the one-time cost and break-even, and
the exposure. A standing allowance lets the spender pull **any** stablecoin the handler holds at any
time, not only during a BitChill call. The decision therefore rests on who controls the spender's code.
Before asking, the implementer records in the PR, for each spender at its canonical deploy address:

- the address and verified source or code hash;
- whether it is a proxy, and who can upgrade it;
- which admin or owner roles it has, and who holds them;
- how its code can move a third party's approved tokens. For SwapRouter02, confirm against the
  deployed code that it only pulls from the payer of the swap in progress.

The questions:

1. **Uniswap router (protocol-paid, every Dex batch).** Should Dex handlers hold a standing
   stablecoin approval to `i_swapRouter02`? The exposure is every stablecoin balance the handler holds
   between calls:
   - For `IdleErc20HandlerDex`, that is **every idle user's deposit**.
   - For a lending Dex handler, it is the transient batch amount plus any donation, dust, or residual
     stablecoin left in the handler.

   Options: keep exact approvals; standing approval on lending Dex handlers only; standing approval on
   all Dex handlers.
2. **Lending spender (user-paid, every lending deposit).** Should lending handlers approve their
   spender (Sovryn iSUSD, LayerBank pool) once, at deploy? The spender already custodies every deposited
   stablecoin as the lending position. The extra exposure is the stablecoin briefly held during a
   deposit or redeem, plus any donation, dust, or residual left in the handler.

If both answers are "keep exact approvals", this item closes with no code change and the reason is
recorded in `IMPLEMENTATION_ORDER.md`.

## Scope

- [ ] Fork-measure whether DOC, USDRIF, and USDT0 decrement a `type(uint256).max` allowance on
      `transferFrom` (read the allowance before and after a spend) and record the result in the PR.
- [ ] Implement the answered option(s) only:
  - **Lending:** add one internal helper to `LendingErc20Handler` that approves `type(uint256).max` to
    `_lendingSpender()`. Call it as the **last statement of each protocol adapter's constructor**
    (`SovrynErc20Handler`, `LayerBankErc20Handler`, `TropykusErc20Handler`). Do **not** call it from
    the `LendingErc20Handler` constructor. `_lendingSpender()` reads an immutable that only the adapter
    constructor assigns, and a base constructor runs first. Calling the virtual hook there compiles
    under both profiles and silently reads `address(0)`: the audit harness reproduced this with solc
    0.8.36. With an OZ token the approval would then revert at deploy; with another token it could
    approve the zero address. Keep the existing `allowance < depositAmount` top-up as the fallback for
    a token that decrements.
  - **Dex:** in the `PurchaseUniswap` constructor, after `i_swapRouter02` is assigned, approve the
    router once for the handler classes the human chose. Then drop the per-batch `forceApprove` there.
    Reading `_purchaseToken()` there is safe: the constructor already depends on the funding base being
    earlier in the leaf's inheritance list, and the router is this contract's own immutable, assigned
    earlier in the same constructor. Leave invariant 12's exact-consumption check exactly as it is.
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
- `src/sovryn/SovrynErc20Handler.sol`, `src/layerbank/LayerBankErc20Handler.sol`,
  `src/tropykus-legacy/TropykusErc20Handler.sol` (the constructor call to the approval helper)
- the Dex / lending leaf headers that gain the standing-approval `@dev` line
- matching unit and fork tests

## Required tests

- Unit, for **each** adapter and leaf that gains an approval. Production handlers are built through
  their deploy scripts per `AGENTS.md`. Tropykus handlers have no live deploy path, since `script/`
  deliberately cannot name a Tropykus route, so build them directly in handler-level tests with
  `new`, as the existing `test/ai-generated/unit/tropykus-legacy/` suites do. In each case:
  - after construction, the stablecoin allowance to the adapter's **real** spender
    (`i_iSusdToken`, `i_pool`, `i_kToken`, `i_swapRouter02`) is `max`;
  - the allowance to `address(0)` is zero, which proves the approval did not run before the immutable
    was set.
- A deposit or batch with the standing approval succeeds and leaves invariant 12's delta check green.
  The fallback top-up still works when a mock token decrements `max`.
- Fork: the allowance-decrement facts for DOC, USDRIF, and USDT0 (Anvil can read them; it does not
  price them).
- A Foundry gas figure per site, labelled Foundry, plus the Rootstock storage derivation from
  `ROOTSTOCK-GAS-SCHEDULE.md`.
- `make check`, `make check-deploy`, `make fork-sovryn`, `make fork-tropykus`, `make fork-dex-path`.

## Success criteria

- [ ] Both product questions are answered and recorded, together with the spender control facts
      above.
- [ ] Only the answered sites change. The steady-state saving, the one-time deploy cost, and the
      break-even are stated on both schedules.
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
