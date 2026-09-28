# R102 — Unwrap WRBTC through the withdraw seam

Status: **implemented** · Assigned: yes · Optional/further-review: no · Stack on: R101 ([#167](https://github.com/BitChillRSK/dca-contracts/pull/167))

## Objective

Stop `PurchaseUniswap` from overriding the guarded external `withdrawAccumulatedRbtc`. Unwrap WRBTC
through the internal `_withdrawRbtc` pay seam instead (same shape as R69's `_depositToken` /
`_withdrawToken`), privatize every encoding and path helper that has a single caller, and fix the
NatSpec that still described pre-R101 / pre-top-up behavior.

## Background

`PurchaseUniswap` was the only contract in `src/` that restated `onlyDcaManager` by overriding a
guarded external. It copied the base's checks-effects call, unwrapped WRBTC, then paid through
`_withdrawRbtc`. That duplicated the entry surface for a venue difference that belongs on the pay
step.

After the seam move, `_withdrawRbtcChecksEffects` and `_claimableRbtc` each have one caller inside
`PurchaseRbtc`, so all three encoding helpers can be `private` — invariant 13 becomes compile-enforced
for the helpers the same way the mapping already was. `_setPurchasePath`, `_setPurchasePathAllowed`,
and `_approveSwapRouter` already had only `PurchaseUniswap` callers (R52), so they become `private`
too.

The companion NatSpec pass fixes three comments that predates later behavior: `tokenBalance` is
remaining principal (not "deposited"); `TokenBalanceUpdated` is also emitted by interest top-up;
`createDcaSchedule`'s `purchaseAmount` is checked against `depositAmount` before tokens move (R101 A);
and LayerBank's exact-burn note covers the batch caller as well as a single redeem.

## Open product decisions

**none**

## Verdicts

| # | Candidate | Verdict | Why |
|---|---|---|---|
| 1 | `PurchaseUniswap` overrides `_withdrawRbtc` (unwrap, then `super`) instead of restating `withdrawAccumulatedRbtc` | **Ship** | One guarded external; venue difference on the pay seam. Behavior unchanged: checks-effects still run before unwrap and native send; any failure rolls the sentinel back. |
| 2 | `_withdrawRbtcChecksEffects` and `_claimableRbtc` become `private` | **Ship** | One caller each after (1). Strengthens invariant 13 with the compiler. |
| 3 | `_setPurchasePath`, `_setPurchasePathAllowed`, `_approveSwapRouter` become `private` | **Ship** | Sole callers are inside `PurchaseUniswap` (R52). Visibility matches reality. |
| 4 | NatSpec for `tokenBalance`, `TokenBalanceUpdated`, create's `purchaseAmount`, LayerBank exact-burn | **Ship** | Comments only; stripped bytecode identical under both profiles. |

## Scope

- [x] `PurchaseRbtc.withdrawAccumulatedRbtc` drops `virtual`; `_withdrawRbtc` becomes `internal virtual`.
- [x] `PurchaseUniswap` deletes its external withdraw override; adds `_withdrawRbtc` override that
      unwraps then `super._withdrawRbtc`.
- [x] `_withdrawRbtcChecksEffects` and `_claimableRbtc` move to `PRIVATE FUNCTIONS` as `private`.
- [x] `_setPurchasePath`, `_setPurchasePathAllowed`, `_approveSwapRouter` become `private`.
- [x] NatSpec fixes on `IDcaManager` and `LayerBankErc20Handler`.
- [x] `AGENTS.md` invariant 13 notes the three helpers are `private` and that wrapped routes override
      `_withdrawRbtc`.

## Out of scope

- [x] Any purchase-path change.
- [x] Any ABI, event, or selector change.
- [x] Rewriting historical specs (R30 still names the old override shape; behavior is unchanged).

## Files likely touched

- `src/PurchaseRbtc.sol`
- `src/PurchaseUniswap.sol`
- `src/interfaces/IDcaManager.sol`
- `src/layerbank/LayerBankErc20Handler.sol`
- `AGENTS.md`
- `docs/relaunch/R102-wrbtc-withdraw-seam.md`
- `docs/relaunch/README.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

- `make check`
- `make fork-sovryn`
- `make fork-layerbank`
- Metadata-stripped runtime and creation comparison vs R101 tip under both profiles (documented in the
  implementing commit): deploy profile identical on all ten deployables; default profile Dex leaves
  grow 5–9 B, everything else identical.
- No new fork-specific assertions; existing Dex withdraw coverage exercises the new seam.

## Success criteria

- [x] Dex withdraw still unwraps then pays the signer; MoC withdraw unchanged.
- [x] Encoding helpers are `private`; a leaf cannot call them.
- [x] No ABI / event / selector change.
- [x] `make check` + both production fork lanes green.
- [x] Spec assigned; README Status and `IMPLEMENTATION_ORDER.md` updated.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (invariant 13 strengthened, not changed).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none — no consumer-visible surface change.
