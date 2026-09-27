# R99 — Centralize measured deposit-share accounting

Status: **implemented** · Assigned: yes · Optional/further-review: no · Stack on: R98

## Objective

Move “read receipt-share balance → deposit → subtract previous balance” out of the three lending
adapters into `LendingHandler._depositToken`, so `_protocolDeposit` is only the protocol call and
protocol-specific failure handling — matching the redemption design (`_protocolRedeem` moves funds;
the base measures).

## Background

Sovryn, LayerBank, and Tropykus each repeat the measured mint pattern. All three already implement
`_receiptSharesBalance()` (used by `_measuredProtocolRedeem`). Folding the delta into the base gives
measured share credits one implementation, preserves LayerBank's scaled accounting, and adds no
state or public interface. No gas claim; this is structural DRY.

Comes from the same 2026-09-27 source-cleanup review that produced
[R98](./R98-remove-unreachable-redeem-clamp.md). Implement after R98 so the redeem-path simplification
and the deposit-path DRY stay separately reviewable.

## Open product decisions

**none**

## Scope

- [x] `LendingHandler._depositToken` measures `mintedShares` via `_receiptSharesBalance()` around
      `_protocolDeposit(depositAmount)`.
- [x] `_protocolDeposit` returns nothing useful (or is `void`) and only performs the protocol mint /
      supply; adapters drop their local before/after balance arithmetic.
- [x] LayerBank still uses `scaledBalanceOf` through `_receiptSharesBalance` — no behaviour change.
- [x] Existing deposit / `UserSharesUpdated` tests still pass; add a harness assertion that the
      credited shares equal the measured external delta.

## Out of scope

- [ ] R98 clamp / event removal.
- [ ] R100 invariant suite work.
- [ ] Changing deposit failure errors or standing approvals.

## Files likely touched

- `src/LendingHandler.sol`
- `src/sovryn/SovrynErc20Handler.sol`
- `src/layerbank/LayerBankErc20Handler.sol`
- `src/tropykus-legacy/TropykusErc20Handler.sol`
- `test/unit/LendingHandlerRedeemTest.t.sol` (harness `_protocolDeposit`)
- matching dedicated handler unit tests if they stub `_protocolDeposit`
- `docs/relaunch/R99-centralize-deposit-share-accounting.md`, `README.md`, `IMPLEMENTATION_ORDER.md`

## Required tests

```text
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path "test/unit/LendingHandlerRedeemTest.t.sol"
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn make moc-sovryn
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank make moc-layerbank
make check
make fork-sovryn
make fork-tropykus
```

## Success criteria

- [x] One measured-mint implementation in the base; adapters have no deposit balance delta math.
- [x] Metadata-stripped behaviour identical aside from any incidental bytecode reshape (no ABI,
      storage, or event change).
- [x] `make check` and both fork lanes green.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Invariant 1 (balance-delta cash on the stablecoin pull) unchanged; share credits still measured,
      never taken from a protocol return.
- [ ] No relaunch ticket ids in `src/` comments.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none.
