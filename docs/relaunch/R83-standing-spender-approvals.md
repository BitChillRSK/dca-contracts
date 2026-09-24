# R83 — standing vs per-use spender approvals

Status: **implemented** · GitHub [#145](https://github.com/BitChillRSK/dca-contracts/pull/145) · Assigned: yes · Optional/further-review: no

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

## Decision (2026-09-24)

Both questions were answered **standing approval**, on the evidence below.

1. **Uniswap router — standing approval on every Dex handler**, idle and lending alike.
2. **Lending spender — standing approval at deploy**, on every protocol adapter.

### Spender control facts

Read at Rootstock mainnet block 9,268,224.

| Spender | Identity | Upgradeable | Controlled by |
|---|---|---|---|
| SwapRouter02 `0x0B14ff67f0014046b4b99057Aec4509640b3947A` | verified `SwapRouter02`, solc 0.7.6, 24,497 bytes, code hash `0x2bc529fc…d870fc` | **no** — no EIP-1967 slots, no `owner()` / `admin()` / `implementation()` | nobody |
| Sovryn iSUSD `0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1` | verified `LoanToken` proxy → `LoanTokenLogicProxy` `0x8Cf4737D…F26e` | yes | `owner()` = timelock `0x967c84b7…F69f` (48 h delay), `admin()` = timelock `0x6c94c8aa…FB13` (24 h), each behind a Bitocracy governor contract; separate pauser `0xDd8e07A5…88b7` |
| LayerBank Pool `0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9` | Aave-v3 `InitializableImmutableAdminUpgradeabilityProxy` → `PoolInstance` revision 7 `0x88919001…0f34` | yes | `PoolAddressesProvider` `0x0c32000a…7052`, whose `owner()` **and** ACL admin is the EOA `0x57b5D81C…9D3a` (codesize 0). No timelock: one transaction replaces the Pool implementation |

### How each spender can move approved tokens

SwapRouter02's verified source has exactly two `transferFrom` sites: `PeripheryPayments.pay`, whose
payer is the `msg.sender` of the swap in progress (or the router itself on later hops of a multi-hop
exact input), and `PeripheryPaymentsExtended.pull`, whose `from` is hardcoded to `msg.sender`. The
callback does read a caller-supplied `payer`, but only a factory-derived pool may call it, and a pool
calls back **whoever invoked `swap`** — so a third party cannot reach that state on somebody else's
behalf. `sweepToken` and `callPositionManager` move the router's own balance, not an approver's.

That reasoning is tested rather than asserted, in
[`test/mainnet-debug/standing-approvals/StandingApprovalProbe.t.sol`](../../test/mainnet-debug/standing-approvals/StandingApprovalProbe.t.sol)
(`make probe-standing-approvals`). Against a victim holding a standing `max` allowance, an attacker's
`pull`, `exactInput`, forged `uniswapV3SwapCallback`, and pool-relayed callback all fail and the balance
is untouched. iSUSD `mint(receiver, amount)` and LayerBank `supply(asset, amount, onBehalfOf, 0)` credit
an arbitrary account but likewise pull only from `msg.sender`; both attacker attempts revert.

### The one entry point that does name a third party

"Pulls only from `msg.sender`" holds for every deposit and redeem entry point, but it is **not** true of
the Aave Pool ABI as a whole, and the first draft of this decision said it was. Aave's `flashLoan` /
`flashLoanSimple` hand the amount to a caller-named `receiverAddress`, require its `executeOperation` to
return true, and then `safeTransferFrom(receiverAddress, aToken, amount + premium)`. An address holding a
standing allowance that answers that callback therefore pays a stranger's premium — 5 bps per call on
this pool, repeatable up to its balance.

Two independent things keep that off a lending handler, and only the second is BitChill's:

1. LayerBank has the reserve-level flash-loan flag **off** for DOC, USDRIF and USDT0. That is their
   configuration, flippable by the same EOA that can upgrade the Pool, so the probe asserts it rather
   than relying on it — twice over, because the first draft of that assertion was wrong. It decoded the
   `ReserveConfigurationMap` with a hand-written bit index and read bit 80, the low bit of the borrow
   cap, instead of bit 63; it passed only because all three live borrow caps (700,000, 700,000 and 0)
   happen to be even, and it would have missed the flag being switched on. The probe now carries no bit
   index at all: it reads Aave's own `getFlashLoanEnabled`, and separately calls `flashLoanSimple` and
   requires the refusal to be exactly `91`, `FLASHLOAN_DISABLED`.
2. A lending handler declares no `executeOperation` and no `fallback` — only `PurchaseRbtc`'s
   `receive()` — so the Pool's callback into it reverts and unwinds the flash loan.

(2) is the one we own, so it is stated as a precondition in `LendingErc20Handler._approveLendingSpender`
and in every lending leaf header, and asserted against a real handler by
`test/unit/StandingApprovalFallbackTest.t.sol`.

**Sovryn is not the same shape, and an earlier draft of this section said it was.** bZx's
`flashBorrowToken` lets its caller name both a `target` and the calldata sent to it; the approver answers
nothing, so declaring no callback defends nothing there. Whether a standing iSUSD allowance would be
exposed turns on who `msg.sender` is at that `target` — the loan token itself, or a separate relay — and
that is not established here, because Sovryn's shipped loan-token logic does not implement the function:
the call reverts with `LoanTokenLogicProxy:target not active`, and `flashBorrowToken` appears nowhere in
the Sovryn source tree outside a diagram. The probe asserts that exact refusal string rather than merely
asserting a revert, since a reinstated `flashBorrowToken` would also revert on the probe's input (it
lends, calls an empty target, and is never repaid) and a bare revert check would sail through the one
change it exists to catch. **The defence at Sovryn is Sovryn governance, not BitChill's callback shape.**
The residual exposure if that changed is bounded by what the handler holds: the stablecoin in flight
during a deposit or redeem, plus dust, since the position itself sits in iSUSD.

So the standing allowance adds no third-party reachability through any entry point the three spenders
expose today — for the router and the Pool because of the precondition above, and for iSUSD because the
one entry point of that shape is not implemented. What it adds is exposure to the spender's own future
code: nil for the router, which cannot change; a 24–48 h governance window at Sovryn; and, at LayerBank,
an instant EOA-controlled upgrade — against a spender that already custodies the whole lending position,
so the extra surface there is the stablecoin transiently held during a deposit or redeem, plus dust.

### Allowance-decrement facts

Live, same probe, same block:

| Token | Decrements a `max` allowance | Per-use saving vs `0 → X → 0` | Break-even |
|---|---|---:|---:|
| USDRIF | no | ~10,400 | ≈ 2 uses |
| DOC | yes (`RESET`) | ~5,400 | ≈ 4 uses |
| USDT0 | yes (`RESET`) | ~5,400 | ≈ 4 uses |

### Measured cost

Per lending deposit, Foundry execution before refunds (`test/gas/R83StandingApprovalGas.t.sol`):
**−23,445** default, **−22,866** under deploy, with allowance-slot writes going **2 → 0**. Each arm is
measured in its own transaction: sharing one made the delta swing by ~10,600 gas on call order alone,
because whichever arm ran first paid the cold access to the stablecoin and the depositor's balance for
both. Cancun refunds
roughly 19,900 of the removed round trip, which is why it never showed up as an Ethereum problem.
Rootstock does not: `SET` 20,000 + `CLEAR` 5,000 − `REFUND` 15,000 = **10,000** net, plus a flat 700 for
the `approve` call. The same test pins the Dex batch at **zero** allowance-slot writes. Against that, each
handler pays one 20,000 `SET` per standing approval at deploy, once, by the deployer.

## Reviewed and kept as-is

Two review points were considered and deliberately not changed.

**The deposit top-up re-approves the exact amount, not `max`.** If it ever fired, the handler would go
back to paying the allowance round trip on every deposit rather than restoring the standing approval.
That branch needs roughly 2²⁵⁶ wei of cumulative spend to become reachable, so it is unreachable in
practice; and keeping the runtime fallback exact means no runtime path can ever widen an allowance —
the unbounded one is granted once, in construction, which is the state that gets audited. The spec
assigned "keep the existing top-up", and this is why keeping it unchanged is the right reading.

**The `allowance()` read stays on the deposit path**, about 900 Rootstock gas (a 700 call plus a 200
read). Dropping it would save that on every deposit but would delete the fallback above. It is present
in both the before and after shapes, so it does not affect any figure quoted here.

## Scope

- [x] Fork-measure whether DOC, USDRIF, and USDT0 decrement a `type(uint256).max` allowance on
      `transferFrom` (read the allowance before and after a spend) and record the result in the PR.
- [x] Implement the answered option(s) only:
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
- [x] State in each affected contract's header `@dev` that the handler holds a standing approval to
      that spender (`AGENTS.md` **Say what is enforced, and what is only assumed**).
- [x] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md`.

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

- [x] Both product questions are answered and recorded, together with the spender control facts
      above.
- [x] Only the answered sites change. The steady-state saving, the one-time deploy cost, and the
      break-even are stated on both schedules.
- [x] Headers state the standing approval where one now exists.

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
